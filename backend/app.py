"""职考通 M1 development API. SQLite is suitable for a single-school pilot.

Only explicit DEV_SEED=true in development creates demonstration accounts/content.
Bootstrap credentials come from the environment; login uses account passwords.
"""
import asyncio
import hashlib
import json
import logging
import os
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Any

import bcrypt
from .question_types import BoundedBodyMiddleware, grade_question
from .content_categories import annotate_questions, category_catalog, filter_category
from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from starlette.middleware.gzip import GZipMiddleware

VERSION = "0.8.7"
logger = logging.getLogger(__name__)
DB_PATH = os.environ.get("DB_PATH", str(Path(__file__).parent / "data" / "zhikaotong.db"))
APP_ENV = os.environ.get("APP_ENV", "production")
VISIBILITY = "教师仅可查看本人当前班级正式在班学生的班内姓名、班级任务成绩及班级科目范围内的学习汇总、当前错题清单和错误分布；不提供私人笔记或自主练习逐题选择。退出班级后不再向原教师显示该学生，学生本人及管理员保留历史任务成绩。"
DEFAULT_SETTINGS = {
    "app_name": "职考通", "current_year": 2027, "exam_start": "2027-04-17",
    "exam_end": "2027-04-18", "agreement_version": "draft-1", "contact": "请学校管理员配置正式联系方式",
    "device_limit": 3, "deletion_cooling_days": 7, "wrong_remove_streak": 2,
    "today_goal": 30, "multiple_rule": "all_or_nothing", "access_token_minutes": 30,
    "refresh_token_days": 30, "login_failure_limit": 5, "login_lock_seconds": 300,
    "app_latest_version": "0.8.3", "app_min_version": "0.1.0", "app_download_url": "",
    "app_update_notes": "单选、多选分开练习与保存进度；题型入口、答题提示和后台筛选更清晰。", "audit_retention_days": 180,
    "backup_retention_days": 30,
}


def now():
    return datetime.now(timezone.utc)


def iso(value=None):
    return (value or now()).isoformat().replace("+00:00", "Z")


def uid():
    return uuid.uuid4().hex


def fail(status, message):
    raise HTTPException(status, message)


def identifier(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 128:
        fail(422, "对象标识须为非空字符串")
    return value


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


@contextmanager
def db():
    conn = sqlite3.connect(DB_PATH, timeout=20)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def rows(conn, sql, args=()):
    return [dict(x) for x in conn.execute(sql, args).fetchall()]


def one(conn, sql, args=()):
    result = conn.execute(sql, args).fetchone()
    return dict(result) if result else None


def settings(conn):
    result = dict(DEFAULT_SETTINGS)
    result.update({r["key"]: json.loads(r["value"]) for r in conn.execute("SELECT * FROM settings")})
    return result


def audit(conn, actor, action, target="", reason=""):
    conn.execute("INSERT INTO audit(id,actor,action,target,reason,created_at) VALUES(?,?,?,?,?,?)",
                 (uid(), actor, action, str(target), reason[:500], iso()))


def password_hash(password):
    if not isinstance(password, str) or not 10 <= len(password) <= 64 or len(password.encode()) > 72:
        fail(422, "密码须为10至64位且UTF-8不超过72字节")
    if not any(x.isalpha() for x in password) or not any(x.isdigit() for x in password):
        fail(422, "密码须同时包含字母和数字")
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()


def check_password(password, hashed):
    try:
        if not isinstance(password, str) or len(password.encode()) > 72:
            return False
        return bcrypt.checkpw(password.encode(), hashed.encode())
    except (ValueError, TypeError):
        return False


def public_user(user):
    keys = ("id", "username", "name", "role", "must_change_password", "activated", "consent_version",
            "birth_year", "subject_group_id", "exam_year", "grade", "target", "enabled", "created_at", "last_login_at")
    result = {k: user.get(k) for k in keys}
    for k in ("must_change_password", "activated", "enabled"):
        result[k] = bool(result[k])
    return result


def roster_user(user):
    """Teachers see administrative roster identity, never private activation/profile fields."""
    result={k: user.get(k) for k in ("id", "username", "name", "role", "enabled", "created_at")}
    result["enabled"]=bool(result["enabled"])
    return result


SCHEMA = """
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,username TEXT NOT NULL UNIQUE,name TEXT NOT NULL,role TEXT NOT NULL CHECK(role IN ('admin','teacher','student')),password_hash TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 1,must_change_password INTEGER NOT NULL DEFAULT 1,activated INTEGER NOT NULL DEFAULT 0,consent_version TEXT,birth_year INTEGER,subject_group_id TEXT,exam_year INTEGER DEFAULT 2027,grade TEXT DEFAULT '',target TEXT DEFAULT '',created_at TEXT NOT NULL,last_login_at TEXT,deleted_at TEXT);
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),access_hash TEXT NOT NULL UNIQUE,refresh_hash TEXT NOT NULL UNIQUE,access_expires TEXT NOT NULL,refresh_expires TEXT NOT NULL,created_at TEXT NOT NULL,revoked INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(user_id,revoked);
CREATE TABLE IF NOT EXISTS refresh_history(token_hash TEXT PRIMARY KEY,session_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS login_limits(key TEXT PRIMARY KEY,failures INTEGER NOT NULL,last_failure REAL NOT NULL);
CREATE TABLE IF NOT EXISTS groups(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,enabled INTEGER NOT NULL DEFAULT 1,subject_ids TEXT NOT NULL DEFAULT '[]');
CREATE TABLE IF NOT EXISTS subjects(id TEXT PRIMARY KEY,name TEXT NOT NULL,group_id TEXT REFERENCES groups(id),full_score INTEGER NOT NULL DEFAULT 100,duration_minutes INTEGER NOT NULL DEFAULT 60);
CREATE TABLE IF NOT EXISTS knowledge(id TEXT PRIMARY KEY,name TEXT NOT NULL,subject_id TEXT NOT NULL REFERENCES subjects(id),parent_id TEXT REFERENCES knowledge(id));
CREATE TABLE IF NOT EXISTS classes(id TEXT PRIMARY KEY,name TEXT NOT NULL,teacher_id TEXT NOT NULL REFERENCES users(id),subject_group_id TEXT NOT NULL REFERENCES groups(id),term TEXT NOT NULL,invite_code TEXT NOT NULL UNIQUE,archived INTEGER NOT NULL DEFAULT 0,approval_required INTEGER NOT NULL DEFAULT 0,created_at TEXT NOT NULL,deleted_at TEXT,deleted_previous_archived INTEGER);
CREATE TABLE IF NOT EXISTS memberships(id TEXT PRIMARY KEY,class_id TEXT NOT NULL REFERENCES classes(id),user_id TEXT NOT NULL REFERENCES users(id),status TEXT NOT NULL,visibility_accepted INTEGER NOT NULL DEFAULT 0,class_name TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL,admin_enrolled_by TEXT REFERENCES users(id),admin_enrolled_at TEXT,UNIQUE(class_id,user_id));
CREATE TABLE IF NOT EXISTS questions(id TEXT PRIMARY KEY,subject_id TEXT NOT NULL REFERENCES subjects(id),knowledge_id TEXT NOT NULL REFERENCES knowledge(id),type TEXT NOT NULL,stem TEXT NOT NULL,options TEXT NOT NULL,answer TEXT NOT NULL,explanation TEXT NOT NULL,difficulty INTEGER NOT NULL,source TEXT NOT NULL,authorization TEXT NOT NULL,status TEXT NOT NULL,creator_id TEXT NOT NULL REFERENCES users(id),reviewer_id TEXT REFERENCES users(id),created_at TEXT NOT NULL,updated_at TEXT NOT NULL,media TEXT NOT NULL DEFAULT '{}');
CREATE TABLE IF NOT EXISTS bank_releases(version INTEGER PRIMARY KEY,questions TEXT NOT NULL,created_at TEXT NOT NULL,creator_id TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),client_uuid TEXT NOT NULL,question_id TEXT NOT NULL REFERENCES questions(id),payload_hash TEXT NOT NULL,selected TEXT NOT NULL,correct INTEGER NOT NULL,duration_seconds INTEGER NOT NULL,answered_at TEXT NOT NULL,received_at TEXT NOT NULL,question_snapshot TEXT NOT NULL DEFAULT '{}',UNIQUE(user_id,client_uuid));
CREATE INDEX IF NOT EXISTS records_user_time ON records(user_id,answered_at);
CREATE INDEX IF NOT EXISTS records_user_question ON records(user_id,question_id,answered_at);
CREATE TABLE IF NOT EXISTS wrong(user_id TEXT NOT NULL REFERENCES users(id),question_id TEXT NOT NULL REFERENCES questions(id),error_count INTEGER NOT NULL DEFAULT 0,last_error_at TEXT,correct_streak INTEGER NOT NULL DEFAULT 0,active INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(user_id,question_id));
CREATE TABLE IF NOT EXISTS marks(user_id TEXT NOT NULL REFERENCES users(id),question_id TEXT NOT NULL REFERENCES questions(id),kind TEXT NOT NULL,active INTEGER NOT NULL,updated_at TEXT NOT NULL,PRIMARY KEY(user_id,question_id,kind));
CREATE TABLE IF NOT EXISTS consents(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),version TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS deletions(user_id TEXT PRIMARY KEY REFERENCES users(id),status TEXT NOT NULL,requested_at TEXT NOT NULL,execute_at TEXT NOT NULL,executed_at TEXT);
CREATE TABLE IF NOT EXISTS tickets(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),kind TEXT NOT NULL,question_id TEXT REFERENCES questions(id),content TEXT NOT NULL,status TEXT NOT NULL DEFAULT 'open',reply TEXT NOT NULL DEFAULT '',created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS announcements(id TEXT PRIMARY KEY,title TEXT NOT NULL,content TEXT NOT NULL,creator_id TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS audit(id TEXT PRIMARY KEY,actor TEXT NOT NULL,action TEXT NOT NULL,target TEXT NOT NULL,reason TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit BEGIN SELECT RAISE(ABORT,'audit entries are immutable'); END;
CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit BEGIN SELECT RAISE(ABORT,'audit entries are immutable'); END;
"""


def create_user(conn, username, name, role, password, must_change=True, activated=False):
    if role not in ("admin", "teacher", "student"):
        fail(422, "角色无效")
    if not isinstance(username, str) or not re.fullmatch(r"[A-Za-z0-9_.@-]{3,64}", username):
        fail(422, "账号须为3至64位字母、数字或 _.@-，且全局唯一")
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 50:
        fail(422, "姓名须为1至50字")
    if one(conn, "SELECT id FROM users WHERE username=?", (username,)):
        fail(409, "账号或学号已存在")
    user_id = uid()
    conn.execute("INSERT INTO users(id,username,name,role,password_hash,must_change_password,activated,created_at) VALUES(?,?,?,?,?,?,?,?)",
                 (user_id, username, name.strip(), role, password_hash(password), int(must_change), int(activated), iso()))
    return one(conn, "SELECT * FROM users WHERE id=?", (user_id,))


def seed(conn):
    if one(conn, "SELECT id FROM users LIMIT 1"):
        return
    if APP_ENV != "development" or os.environ.get("DEV_SEED", "").lower() != "true":
        password = os.environ.get("BOOTSTRAP_ADMIN_PASSWORD")
        if password:
            create_user(conn, "admin", "平台管理员", "admin", password, True, True)
        return
    actors = {}
    for username, role, name in (("admin", "admin", "平台管理员"), ("reviewer", "admin", "内容审核员"), ("teacher", "teacher", "陈老师"), ("student", "student", "演示学生")):
        password = os.environ.get("BOOTSTRAP_" + username.upper() + "_PASSWORD")
        if not password:
            raise RuntimeError("Explicit development seed requires BOOTSTRAP_" + username.upper() + "_PASSWORD")
        actors[username] = create_user(conn, username, name, role, password, username == "student", role != "student")
    conn.execute("INSERT INTO groups(id,name,enabled,subject_ids) VALUES('group-mechanics','机械专业',1,?)", (json.dumps(["chinese", "math", "english", "mechanics", "politics"]),))
    for sid, name, score, duration in (("chinese", "语文", 150, 150), ("math", "数学", 150, 120), ("english", "英语", 100, 120), ("mechanics", "机械专业综合理论", 300, 150), ("politics", "思想政治", 100, 60)):
        conn.execute("INSERT INTO subjects(id,name,group_id,full_score,duration_minutes) VALUES(?,?,'group-mechanics',?,?)", (sid, name, score, duration))
        conn.execute("INSERT INTO knowledge(id,name,subject_id) VALUES(?,?,?)", (sid + "-basic", {"chinese": "语言文字运用", "math": "集合与函数", "english": "词汇与语法", "mechanics": "机械基础", "politics": "政治基础"}[sid], sid))
    cls = uid()
    conn.execute("INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,created_at) VALUES(?,?,?,'group-mechanics',?,?,?)", (cls, "2027 机械升学一班", actors["teacher"]["id"], "2026—2027 学年", secrets.token_hex(4).upper(), iso()))
    conn.execute("INSERT INTO memberships(id,class_id,user_id,status,created_at) VALUES(?,?,?,'pending_confirmation',?)", (uid(), cls, actors["student"]["id"], iso()))
    # Demonstration content is a test fixture, never an automatic school bank.
    if os.environ.get("DEV_SEED_QUESTIONS", "").lower() != "true":
        return
    demo = [
        ("math", "single", "【演示题】已知集合 A={1,2,3}，B={2,3,4}，则 A∩B 等于（ ）。", ["{1,4}", "{2,3}", "{1,2,3,4}", "{3}"], ["B"], "交集由同时属于两个集合的元素组成，因此 A∩B={2,3}。"),
        ("math", "single", "【演示题】函数 y=2x+1 在 x=3 时的函数值是（ ）。", ["5", "6", "7", "8"], ["C"], "将 x=3 代入，y=2×3+1=7。"),
        ("math", "multiple", "【演示题】下列数中，大于 0 的有（ ）。", ["-2", "1", "3", "0"], ["B", "C"], "正数大于零，1 和 3 符合。多选题须全对得分。"),
        ("chinese", "single", "【演示题】下列词语中，书写正确的一项是（ ）。", ["再接再厉", "再接再励", "一愁莫展", "迫不急待"], ["A"], "规范写法为“再接再厉”“一筹莫展”“迫不及待”。"),
        ("chinese", "judge", "【演示题】比喻是一种常见的修辞手法。", ["正确", "错误"], ["A"], "比喻通过具有相似点的事物来描写或说明事物。"),
        ("english", "single", "【演示题】She ___ to school every day.", ["go", "goes", "going", "gone"], ["B"], "主语 She 为第三人称单数，一般现在时谓语用 goes。"),
        ("english", "single", "【演示题】Choose the opposite of “early”.", ["late", "fast", "small", "young"], ["A"], "early（早）的反义词为 late（晚）。"),
        ("mechanics", "single", "【演示题】普通螺纹的公称直径是指（ ）。", ["小径", "中径", "大径", "螺距"], ["C"], "普通螺纹的公称直径为大径。本题为功能演示内容，非考试真题。"),
        ("mechanics", "judge", "【演示题】齿轮传动可以传递运动和动力。", ["正确", "错误"], ["A"], "齿轮通过轮齿啮合传递运动和动力。"),
        ("mechanics", "multiple", "【演示题】以下属于常用机械传动方式的有（ ）。", ["带传动", "齿轮传动", "链传动", "绝缘传动"], ["A", "B", "C"], "带传动、齿轮传动和链传动是常用机械传动方式。"),
    ]
    for sid, kind, stem, opts, answer, explanation in demo:
        conn.execute("INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", (uid(), sid, sid + "-basic", kind, stem, canonical([{"key": chr(65+i), "text": v} for i,v in enumerate(opts)]), canonical(answer), explanation, 1, "平台自编功能演示，非考试真题", "仅供开发功能验证；正式题库需独立授权和审核", "published", actors["admin"]["id"], actors["reviewer"]["id"], iso(), iso()))
    publish_bank(conn, actors["admin"]["id"])
    conn.execute("INSERT INTO announcements VALUES(?,?,?,?,?)", (uid(), "欢迎使用职考通开发验证版", "当前题目为自编演示内容，考试日期为需求预设日期，正式上线前需以官方方案及授权题库替换。", actors["admin"]["id"], iso()))
    audit(conn, "system", "seed.development", "demo", "Explicit DEV_SEED=true")


def initialize():
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.executescript(SCHEMA)
        if "question_snapshot" not in {r["name"] for r in conn.execute("PRAGMA table_info(records)")}:
            conn.execute("ALTER TABLE records ADD COLUMN question_snapshot TEXT NOT NULL DEFAULT '{}'")
        if "media" not in {r["name"] for r in conn.execute("PRAGMA table_info(questions)")}:
            conn.execute("ALTER TABLE questions ADD COLUMN media TEXT NOT NULL DEFAULT '{}'")
        class_columns = {r["name"] for r in conn.execute("PRAGMA table_info(classes)")}
        if "deleted_at" not in class_columns:
            conn.execute("ALTER TABLE classes ADD COLUMN deleted_at TEXT")
        if "deleted_previous_archived" not in class_columns:
            conn.execute("ALTER TABLE classes ADD COLUMN deleted_previous_archived INTEGER")
        membership_columns = {r["name"] for r in conn.execute("PRAGMA table_info(memberships)")}
        if "admin_enrolled_by" not in membership_columns:
            conn.execute("ALTER TABLE memberships ADD COLUMN admin_enrolled_by TEXT REFERENCES users(id)")
        if "admin_enrolled_at" not in membership_columns:
            conn.execute("ALTER TABLE memberships ADD COLUMN admin_enrolled_at TEXT")
        seed(conn)


def execute_deletions(conn):
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    due = rows(conn, "SELECT user_id FROM deletions WHERE status='pending' AND execute_at<=?", (iso(),))
    for item in due:
        user_id = item["user_id"]
        anonymous = "deleted-" + uid()
        conn.execute("UPDATE users SET username=?,name='已注销用户',password_hash='',enabled=0,activated=0,birth_year=NULL,subject_group_id=NULL,grade='',target='',consent_version=NULL,last_login_at=NULL,deleted_at=? WHERE id=?", (anonymous, iso(), user_id))
        conn.execute("UPDATE sessions SET revoked=1 WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM marks WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM wrong WHERE user_id=?", (user_id,))
        conn.execute("DELETE FROM records WHERE user_id=?", (user_id,))
        conn.execute("UPDATE memberships SET status='left',class_name='' WHERE user_id=?", (user_id,))
        conn.execute("UPDATE tickets SET content='[注销已删除]',reply='' WHERE user_id=?", (user_id,))
        conn.execute("UPDATE deletions SET status='executed',executed_at=? WHERE user_id=?", (iso(), user_id))
        audit(conn, "system", "user.deletion.executed", user_id)
    return len(due)


async def deletion_worker():
    while True:
        await asyncio.sleep(60)
        try:
            with db() as conn:
                execute_deletions(conn)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            # Keep the execution chain alive after a transient database failure.
            # Exception text may contain SQL data, so log its type only.
            logger.error("deletion_worker_retry error_type=%s",type(exc).__name__)


@asynccontextmanager
async def lifespan(app):
    initialize()
    with db() as conn:
        execute_deletions(conn)
    worker = asyncio.create_task(deletion_worker())
    yield
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass


app = FastAPI(title="职考通 API", version=VERSION, lifespan=lifespan, docs_url="/api/docs" if APP_ENV == "development" else None)
app.add_middleware(GZipMiddleware,minimum_size=4096,compresslevel=5)


@app.exception_handler(sqlite3.IntegrityError)
async def integrity_error(request, exc):
    return JSONResponse({"detail":"数据存在唯一性或引用冲突，请刷新后重试"},status_code=409)


@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Frame-Options"] = "DENY"
    return response


def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def app_surface(request):
    """The mobile gateway overwrites this header; it only removes privileges."""
    return request is not None and request.headers.get("x-zhikaotong-surface", "").strip().lower() == "app"


def require_surface_role(request, user):
    if app_surface(request) and user["role"] == "admin":
        fail(403, "该入口仅供学生和教师使用，管理员请使用管理后台")


def auth(request: Request, authorization: Annotated[str | None, Header()] = None):
    if not authorization or not authorization.startswith("Bearer "):
        fail(401, "请先登录")
    with db() as conn:
        token = authorization[7:]
        session = one(conn, "SELECT * FROM sessions WHERE access_hash=? AND revoked=0 AND access_expires>?", (hash_token(token), iso()))
        if not session:
            fail(401, "登录已失效，请重新登录")
        user = one(conn, "SELECT * FROM users WHERE id=? AND enabled=1 AND deleted_at IS NULL", (session["user_id"],))
        if not user:
            fail(401, "账号已停用")
        require_surface_role(request, user)
        user["session_id"] = session["id"]
        return user


def ready(user=Depends(auth)):
    if user["must_change_password"]:
        fail(403, "首次登录须先修改密码")
    if user["role"] == "student":
        with db() as conn:
            cfg = settings(conn)
            if not user["activated"]:
                fail(403, "请先完成首次激活")
            if user["consent_version"] != cfg["agreement_version"]:
                fail(403, "请先同意最新版本协议")
    return user


def student(user=Depends(ready)):
    if user["role"] != "student":
        fail(403, "仅学生可操作")
    return user


def manager(user=Depends(ready)):
    if user["role"] not in ("teacher", "admin"):
        fail(403, "无管理权限")
    return user


def admin(user=Depends(manager)):
    if user["role"] != "admin":
        fail(403, "仅管理员可操作")
    return user


def class_scope(conn, class_id, actor, writable=False, allow_deleted=False):
    identifier(class_id)
    if writable and not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    item = one(conn, "SELECT * FROM classes WHERE id=?", (class_id,))
    if not item:
        fail(404, "班级不存在")
    if item["deleted_at"] and not allow_deleted:
        fail(404, "班级不存在或已删除")
    if actor["role"] != "admin" and item["teacher_id"] != actor["id"]:
        fail(403, "无权操作此班级")
    if writable and (item["archived"] or item["deleted_at"]):
        fail(409, "归档班级只读")
    return item


def user_scope(conn, user_id, actor, writable=False):
    identifier(user_id)
    if writable and not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    item = one(conn, "SELECT * FROM users WHERE id=? AND deleted_at IS NULL", (user_id,))
    if not item:
        fail(404, "用户不存在")
    if actor["role"] != "admin":
        allowed = one(conn, "SELECT m.id FROM memberships m JOIN classes c ON c.id=m.class_id WHERE m.user_id=? AND c.teacher_id=? AND m.status IN ('active','pending_confirmation','pending_approval') AND c.archived=0 AND c.deleted_at IS NULL", (user_id, actor["id"]))
        if item["role"] != "student" or not allowed:
            fail(403, "无权操作此用户")
    return item


def issue_tokens(conn, user, session_id=None):
    cfg = settings(conn)
    access, refresh = secrets.token_urlsafe(40), secrets.token_urlsafe(48)
    values = (hash_token(access), hash_token(refresh), iso(now()+timedelta(minutes=cfg["access_token_minutes"])), iso(now()+timedelta(days=cfg["refresh_token_days"])))
    if session_id:
        old = one(conn, "SELECT refresh_hash FROM sessions WHERE id=?", (session_id,))
        conn.execute("INSERT OR IGNORE INTO refresh_history VALUES(?,?)", (old["refresh_hash"], session_id))
        conn.execute("UPDATE sessions SET access_hash=?,refresh_hash=?,access_expires=?,refresh_expires=? WHERE id=? AND revoked=0", values + (session_id,))
    else:
        active = rows(conn, "SELECT id FROM sessions WHERE user_id=? AND revoked=0 AND refresh_expires>? ORDER BY created_at DESC", (user["id"], iso()))
        for session in active[max(0,cfg["device_limit"]-1):]:
            conn.execute("UPDATE sessions SET revoked=1 WHERE id=?", (session["id"],))
        conn.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?,?,0)", (uid(), user["id"], *values, iso()))
    return {"access_token": access, "refresh_token": refresh, "token_type": "bearer", "user": public_user(user)}


@app.get("/api/health")
def health():
    return {"status": "ok", "version": VERSION}


@app.get("/api/public/config")
def public_config():
    with db() as conn:
        cfg = settings(conn)
        return {**{k: cfg[k] for k in ("app_name", "current_year", "exam_start", "exam_end", "agreement_version", "contact", "app_latest_version", "app_min_version", "app_download_url", "app_update_notes")}, "teacher_visibility": VISIBILITY,
                "subjects": rows(conn, "SELECT id,name FROM subjects"), "subject_groups": rows(conn, "SELECT id,name FROM groups WHERE enabled=1")}


@app.get("/api/public/legal")
def public_legal():
    with db() as conn:
        cfg = settings(conn)
    return {"version": cfg["agreement_version"], "privacy": "【开发草案，尚未完成上线合规审查】职考通供学生与教师进行校内备考和教学使用。学生激活需年满14周岁，教师账号不填写学生激活资料。账号由学校管理员或教师按权限开通；本平台处理账号、学生出生年份、班级及必要学习记录，用于认证、判分与学习统计。教师可见范围：" + VISIBILITY + "不接入第三方统计或广告SDK，不申请位置、通讯录、短信或通话记录权限。学生注销冷静期为" + str(cfg["deletion_cooling_days"]) + "天，到期删除自主练习记录、收藏和错题并匿名化账号；审计日志目标保留期限配置为" + str(cfg["audit_retention_days"]) + "天，备份目标保留期限配置为" + str(cfg["backup_retention_days"]) + "天。审计日志自动清理、备份轮换和恢复演练尚待运营环境配置与验证，当前不代表已执行的保留承诺。正式运营方、联系方式、备案号、备份删除范围及申诉流程须由运营者完成核验。联系：" + cfg["contact"],
            "agreement": "【开发草案】本应用用于学生校内职教高考备考和教师组织班级练习。账号不可转借，题目内容不得擅自传播。当前演示题并非考试真题，需求预设考试日期并非官方核定。正式版本需由学校核定考试方案及题库授权。学生未满14周岁不得激活。学生可在设置中申请更正、投诉和注销；教师相关请求请联系学校管理员。"}


@app.post("/api/auth/login")
def login(data: dict = Body(...), request: Request = None):
    username = str(data.get("username", ""))[:64]
    password = data.get("password", "")
    # The mobile endpoint must not validate administrator passwords, issue their
    # sessions, or let mobile attempts lock out the private management login.
    if app_surface(request):
        with db() as conn:
            blocked = one(conn, "SELECT id FROM users WHERE username=? AND role='admin' AND deleted_at IS NULL", (username,))
            if blocked:
                audit(conn, "anonymous", "auth.login.surface_denied", username)
        if blocked:
            fail(403, "该入口仅供学生和教师使用，管理员请使用管理后台")
    client = request.client.host if request and request.client else "local"
    limit_keys = ("user:" + username, "ip:" + client)
    error = None
    response = None
    with db() as conn:
        cfg = settings(conn)
        for key in limit_keys:
            limit = one(conn, "SELECT * FROM login_limits WHERE key=?", (key,))
            if limit and limit["failures"] >= (cfg["login_failure_limit"] if key.startswith("user:") else 50) and time.time()-limit["last_failure"] < cfg["login_lock_seconds"]:
                fail(429, "尝试次数过多，请稍后再试")
        user = one(conn, "SELECT * FROM users WHERE username=? AND deleted_at IS NULL", (username,))
        valid = user and user["enabled"] and check_password(password, user["password_hash"])
        if not valid:
            conn.execute("BEGIN IMMEDIATE")
            for key in limit_keys:
                old = one(conn, "SELECT * FROM login_limits WHERE key=?", (key,))
                count = old["failures"] + 1 if old and time.time()-old["last_failure"] < cfg["login_lock_seconds"] else 1
                conn.execute("INSERT INTO login_limits VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET failures=excluded.failures,last_failure=excluded.last_failure", (key, count, time.time()))
            audit(conn, "anonymous", "auth.login.failed", username)
            error = (401, "账号或密码不正确")
        else:
            # Hash verification runs before taking SQLite's write lock. Session
            # limits and issuance are serialized only after credentials are checked.
            conn.execute("BEGIN IMMEDIATE")
            current=one(conn,"SELECT * FROM users WHERE id=? AND enabled=1 AND deleted_at IS NULL",(user["id"],))
            if not current or current["password_hash"]!=user["password_hash"]:
                fail(401,"账号或密码不正确")
            conn.execute("DELETE FROM login_limits WHERE key=?", (limit_keys[0],))
            conn.execute("UPDATE users SET last_login_at=? WHERE id=?", (iso(), user["id"]))
            # A login during the cooling period explicitly cancels a pending request.
            pending = one(conn, "SELECT * FROM deletions WHERE user_id=? AND status='pending'", (user["id"],))
            if pending:
                if pending["execute_at"] <= iso():
                    execute_deletions(conn)
                    error = (401, "账号或密码不正确")
                else:
                    conn.execute("UPDATE deletions SET status='cancelled' WHERE user_id=?", (user["id"],))
                    audit(conn, user["id"], "user.deletion.cancelled.login", user["id"])
            if not error:
                response = issue_tokens(conn, user)
                audit(conn, user["id"], "auth.login", user["id"])
    if error:
        fail(*error)
    return response


@app.post("/api/auth/refresh")
def refresh(data: dict = Body(...), request: Request = None):
    token = data.get("refresh_token", "")
    if not isinstance(token, str) or len(token) > 256:
        fail(401, "刷新令牌无效")
    error = None
    result = None
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        token_hash = hash_token(token)
        item = one(conn, "SELECT * FROM sessions WHERE refresh_hash=? AND revoked=0 AND refresh_expires>?", (token_hash, iso()))
        if not item:
            reused = one(conn, "SELECT h.session_id,u.role FROM refresh_history h JOIN sessions s ON s.id=h.session_id JOIN users u ON u.id=s.user_id WHERE h.token_hash=?", (token_hash,))
            if reused:
                # A token issued to the private admin surface cannot be used on
                # the phone gateway to revoke that administrator's new session.
                require_surface_role(request, reused)
                conn.execute("UPDATE sessions SET revoked=1 WHERE id=?", (reused["session_id"],))
            error = True
        else:
            user = one(conn, "SELECT * FROM users WHERE id=? AND enabled=1 AND deleted_at IS NULL", (item["user_id"],))
            if not user:
                error = True
            else:
                require_surface_role(request, user)
                result = issue_tokens(conn, user, item["id"])
    if error:
        fail(401, "刷新令牌失效，请重新登录")
    return result


@app.post("/api/auth/logout")
def logout(data: dict = Body(...), user=Depends(auth)):
    with db() as conn:
        # The authenticated current session is always revoked, regardless of a stale refresh value.
        conn.execute("UPDATE sessions SET revoked=1 WHERE id=? AND user_id=?", (user["session_id"], user["id"]))
        audit(conn, user["id"], "auth.logout", user["id"])
    return {"ok": True}


@app.get("/api/auth/me")
def me(user=Depends(auth)):
    return public_user(user)


@app.post("/api/auth/password")
def change_password(data: dict = Body(...), user=Depends(auth)):
    if not check_password(data.get("old_password"), user["password_hash"]):
        fail(400, "原密码不正确")
    if data.get("new_password") == data.get("old_password"):
        fail(422, "新密码不能与初始密码相同")
    hashed = password_hash(data.get("new_password"))
    with db() as conn:
        conn.execute("UPDATE users SET password_hash=?,must_change_password=0 WHERE id=?", (hashed, user["id"]))
        conn.execute("UPDATE sessions SET revoked=1 WHERE user_id=? AND id<>?", (user["id"], user["session_id"]))
        audit(conn, user["id"], "auth.password.changed", user["id"])
    return {"ok": True}


@app.post("/api/student/activate")
def activate(data: dict = Body(...), user=Depends(auth)):
    if user["role"] != "student":
        fail(403, "仅学生可激活")
    if user["must_change_password"]:
        fail(403, "请先修改初始密码")
    if user["activated"]:
        fail(409, "账号已激活，修改备考信息请联系管理员")
    year = data.get("birth_year")
    if not isinstance(year, int) or isinstance(year, bool) or not 1900 <= year <= now().year:
        fail(422, "出生年份无效")
    # Birth year alone cannot prove the exact birthday; require calendar-year age >=14.
    if now().year - year < 14:
        fail(403, "未满14周岁不允许激活")
    with db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        cfg = settings(conn)
        if data.get("consent_version") != cfg["agreement_version"]:
            fail(409, "请阅读并同意当前版本协议")
        if not data.get("teacher_visibility_accepted"):
            fail(422, "请确认教师可见数据范围")
        if user["subject_group_id"] and data.get("subject_group_id") != user["subject_group_id"]:
            fail(403, "账号专业已由学校分配，请使用已分配的专业")
        group = one(conn, "SELECT * FROM groups WHERE id=? AND enabled=1", (identifier(data.get("subject_group_id")),))
        if not group:
            fail(422, "科目组不存在或已停用")
        assigned_classes=rows(conn,"""SELECT g.subject_ids FROM memberships m JOIN classes c ON c.id=m.class_id
          JOIN groups g ON g.id=c.subject_group_id WHERE m.user_id=? AND m.status IN ('active','pending_confirmation','pending_approval')
          AND c.archived=0 AND c.deleted_at IS NULL""",(user['id'],))
        chosen_subjects=set(json.loads(group['subject_ids']))
        if any(not set(json.loads(item['subject_ids'])).issubset(chosen_subjects) for item in assigned_classes):
            fail(409,'所选专业与学校分配的班级科目范围不兼容，请联系管理员核对')
        name = str(data.get("name", user["name"])).strip()
        if not 1 <= len(name) <= 50:
            fail(422, "姓名须为1至50字")
        exam_year = data.get("exam_year", cfg["current_year"])
        if not isinstance(exam_year, int) or not now().year <= exam_year <= now().year + 10:
            fail(422, "考试年份无效")
        conn.execute("UPDATE users SET activated=1,birth_year=?,name=?,subject_group_id=?,exam_year=?,grade=?,target=?,consent_version=? WHERE id=?", (year, name, group["id"], exam_year, str(data.get("grade", ""))[:40], str(data.get("target", ""))[:200], cfg["agreement_version"], user["id"]))
        conn.execute("INSERT INTO consents VALUES(?,?,?,?)", (uid(), user["id"], cfg["agreement_version"], iso()))
        audit(conn, user["id"], "student.activated", user["id"])
        return public_user(one(conn, "SELECT * FROM users WHERE id=?", (user["id"],)))


@app.post("/api/student/consent")
def consent(data: dict = Body(...), user=Depends(auth)):
    if user["role"] != "student":
        fail(403, "仅学生可操作")
    with db() as conn:
        version = settings(conn)["agreement_version"]
        if data.get("version") != version:
            fail(409, "协议版本已更新")
        conn.execute("UPDATE users SET consent_version=? WHERE id=?", (version, user["id"]))
        conn.execute("INSERT INTO consents VALUES(?,?,?,?)", (uid(), user["id"], version, iso()))
        return public_user(one(conn, "SELECT * FROM users WHERE id=?", (user["id"],)))


def question_public(item, version=0):
    result = {k: item[k] for k in ("id", "subject_id", "knowledge_id", "type", "stem", "explanation", "difficulty", "source")}
    for key in ("options", "answer"):
        result[key] = json.loads(item[key]) if isinstance(item[key], str) else item[key]
    result["version"] = version
    media = item.get('media') or {}
    if isinstance(media, str):
        media = json.loads(media)
    if media:
        result['media'] = media
    return result


def require_media_capability(request, questions):
    if app_surface(request) and request.headers.get('X-Question-Content') != 'media-v1' and any(question.get('media') for question in questions):
        fail(426,'这批题目含原图和公式，请覆盖安装职考通0.5.0或以上版本后继续；已保存的作答仍可同步')


def publish_bank(conn, actor):
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    version = conn.execute("SELECT COALESCE(MAX(version),0)+1 FROM bank_releases").fetchone()[0]
    questions = [question_public(q, version) for q in rows(conn, "SELECT * FROM questions WHERE status='published' ORDER BY id")]
    conn.execute("INSERT INTO bank_releases VALUES(?,?,?,?)", (version, canonical(questions), iso(), actor))
    audit(conn, actor, "bank.publish", str(version))
    return {"version": version, "count": len(questions)}


def current_bank(conn):
    release = one(conn, "SELECT * FROM bank_releases ORDER BY version DESC LIMIT 1")
    if not release:
        return 0, []
    return release["version"], json.loads(release["questions"])


def allowed_subjects(conn, user):
    group = one(conn, "SELECT subject_ids FROM groups WHERE id=? AND enabled=1", (user["subject_group_id"],))
    return json.loads(group["subject_ids"]) if group else []


def student_questions(conn, user, subject_id=None):
    version, questions = current_bank(conn)
    allowed = set(allowed_subjects(conn, user))
    names = {subject['id']: subject['name'] for subject in rows(conn, 'SELECT id,name FROM subjects')}
    visible = [q for q in questions if q["subject_id"] in allowed and (not subject_id or q["subject_id"] == subject_id)]
    return version, annotate_questions(visible, names)


def subject_stats(conn, user):
    allowed = set(allowed_subjects(conn, user))
    _, bank = current_bank(conn)
    published = {sid: {"total": 0, "by_type": dict.fromkeys(("single", "multiple", "judge", "fill"), 0)} for sid in allowed}
    for question in bank:
        counts = published.get(question["subject_id"])
        if counts is not None:
            counts["total"] += 1
            if question["type"] in counts["by_type"]:
                counts["by_type"][question["type"]] += 1
    result = []
    for sub in rows(conn, "SELECT * FROM subjects ORDER BY rowid"):
        if sub["id"] not in allowed:
            continue
        total = one(conn, "SELECT COUNT(*) answered,COALESCE(SUM(correct),0) correct FROM records WHERE user_id=? AND question_id IN(SELECT id FROM questions WHERE subject_id=?)", (user["id"], sub["id"]))
        result.append({**sub, **published[sub["id"]], "categories": category_catalog(bank, sub['id'], sub['name']), "answered": total["answered"], "accuracy": round(total["correct"] * 100 / total["answered"], 1) if total["answered"] else 0})
    return result


def classes_for_student(conn, user):
    return [{**r, "admin_enrolled":bool(r["admin_enrolled"]), "enrollment_source":"admin" if r["admin_enrolled"] else "student_confirmation", "visibility": VISIBILITY} for r in rows(conn, "SELECT c.id,c.name,t.name teacher_name,m.status,m.class_name,c.archived,(m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL) admin_enrolled FROM memberships m JOIN classes c ON c.id=m.class_id JOIN users t ON t.id=c.teacher_id WHERE m.user_id=? AND m.status NOT IN ('left','rejected') AND c.deleted_at IS NULL", (user["id"],))]


@app.get("/api/student/dashboard")
def student_dashboard(user=Depends(student)):
    with db() as conn:
        cfg = settings(conn)
        agg = one(conn, "SELECT COUNT(*) answered,COALESCE(SUM(correct),0) correct,COALESCE(SUM(duration_seconds),0) study_seconds FROM records WHERE user_id=?", (user["id"],))
        days = {r["day"] for r in rows(conn, "SELECT DISTINCT date(answered_at,'+8 hours') day FROM records WHERE user_id=?", (user["id"],))}
        streak = 0
        day = (now()+timedelta(hours=8)).date()
        if day.isoformat() not in days:
            day -= timedelta(days=1)
        while day.isoformat() in days:
            streak += 1
            day -= timedelta(days=1)
        today = conn.execute("SELECT COUNT(*) FROM records WHERE user_id=? AND date(answered_at,'+8 hours')=?", (user["id"], (now()+timedelta(hours=8)).date().isoformat())).fetchone()[0]
        return {"user": public_user(user), "stats": {**agg, "accuracy": round(agg["correct"]*100/agg["answered"],1) if agg["answered"] else 0, "streak": streak, "today_answered": today, "today_goal": cfg["today_goal"]}, "subjects": subject_stats(conn, user), "exam_start": cfg["exam_start"], "exam_end": cfg["exam_end"], "announcements": rows(conn, "SELECT id,title,content,created_at FROM announcements ORDER BY created_at DESC LIMIT 10"), "classes": classes_for_student(conn, user)}


@app.get("/api/subjects")
def subjects(user=Depends(student)):
    with db() as conn:
        return subject_stats(conn, user)


@app.get("/api/knowledge")
def knowledge(subject_id: str | None = None, user=Depends(student)):
    with db() as conn:
        allowed = allowed_subjects(conn, user)
        return [x for x in rows(conn, "SELECT * FROM knowledge") if x["subject_id"] in allowed and (not subject_id or x["subject_id"] == subject_id)]


@app.get("/api/questions")
def get_questions(request:Request,subject_id: str | None = None, mode: str = "all", limit: int = Query(20, ge=1, le=200), knowledge_id: str | None = None, type: str | None = None, difficulty: int | None = None, shuffle: bool = False, category_id: str | None = Query(None, max_length=64), user=Depends(student)):
    if mode not in ("all", "wrong", "favorite", "random"):
        fail(422, "练习模式无效")
    with db() as conn:
        if category_id and subject_id and subject_id not in allowed_subjects(conn, user):
            fail(403, '该科目不在当前备考范围，请刷新首页')
        _, questions = student_questions(conn, user, subject_id)
        questions = filter_category(sys.modules[__name__], questions, subject_id, category_id)
        if mode in ("wrong", "favorite"):
            sql = "SELECT question_id FROM wrong WHERE user_id=? AND active=1" if mode == "wrong" else "SELECT question_id FROM marks WHERE user_id=? AND kind='favorite' AND active=1"
            ids = {r[0] for r in conn.execute(sql, (user["id"],))}
            questions = [q for q in questions if q["id"] in ids]
        questions = [q for q in questions if (not knowledge_id or q["knowledge_id"] == knowledge_id) and (not type or q["type"] == type) and (not difficulty or q["difficulty"] == difficulty)]
        if mode == "random" or shuffle:
            secrets.SystemRandom().shuffle(questions)
        selected = questions[:limit]
        require_media_capability(request,selected)
        return selected


@app.post("/api/student/records/batch")
def submit_records(data: dict = Body(...), user=Depends(student)):
    records = data.get("records")
    if not isinstance(records, list) or not 1 <= len(records) <= 200:
        fail(422, "每批须包含1至200条记录")
    result = {"accepted": 0, "duplicates": 0, "results": []}
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        cfg = settings(conn)
        _, questions = student_questions(conn, user)
        bank = {q["id"]: q for q in questions}
        touched=set()
        for item in records:
            if not isinstance(item, dict):
                fail(422, "记录格式无效")
            client_id = item.get("client_uuid")
            try:
                uuid.UUID(client_id)
            except (ValueError, TypeError, AttributeError):
                fail(422, "client_uuid须为有效UUID")
            selected = item.get("selected")
            if not isinstance(selected, list) or not all(isinstance(x,str) and len(x)<=1000 for x in selected) or len(selected)>20:
                fail(422, "作答选项无效")
            duration = item.get("duration_seconds")
            if not isinstance(duration, (int,float)) or isinstance(duration,bool) or not 0 <= duration <= 86400:
                fail(422, "做题用时无效")
            try:
                answered = datetime.fromisoformat(str(item.get("answered_at", "")).replace("Z", "+00:00"))
                if answered.tzinfo is None or answered > now()+timedelta(minutes=5) or answered < now()-timedelta(days=365):
                    raise ValueError()
            except (ValueError,TypeError):
                fail(422, "答题时间无效，应为带时区的近一年时间")
            question_id=item.get("question_id")
            if not isinstance(question_id,str):fail(422,"题目编号无效")
            old = one(conn, "SELECT * FROM records WHERE user_id=? AND client_uuid=?", (user["id"], client_id))
            q = json.loads(old['question_snapshot']) if old else bank.get(question_id)
            if not old and 'question_version' in item and isinstance(item['question_version'],int) and not isinstance(item['question_version'],bool):
                release=one(conn,"SELECT questions FROM bank_releases WHERE version=?",(item['question_version'],))
                q=next((x for x in json.loads(release['questions']) if x['id']==question_id),None) if release else None
            if old and not q:
                live=one(conn,"SELECT * FROM questions WHERE id=?",(old['question_id'],))
                q=question_public(live) if live else {"answer":[],"explanation":"历史记录","type":"single"}
            ordered = list(selected) if q and q.get('type') == 'fill' else sorted(selected)
            normalized = {"question_id": question_id, "selected": ordered, "duration_seconds": int(duration), "answered_at": iso(answered.astimezone(timezone.utc))}
            if "question_version" in item:
                if not isinstance(item["question_version"],int) or isinstance(item["question_version"],bool):fail(422,"题库版本无效")
                normalized["question_version"]=item["question_version"]
            payload_hash = hash_token(canonical(normalized))
            if old:
                if old["payload_hash"] != payload_hash:
                    fail(409, "相同UUID已用于不同记录")
                result["duplicates"] += 1
                correct = bool(old["correct"])
            else:
                if not q or q["subject_id"] not in allowed_subjects(conn,user):
                    fail(422,"题目不在已发布的可用题库版本")
                if q['type'] == 'fill':
                    if len(selected) != len(q['answer']):fail(422,'填空作答数量与空位数不匹配')
                else:
                    keys={opt["key"] for opt in q["options"]}
                    if len(set(selected)) != len(selected) or not set(selected).issubset(keys):fail(422,"作答选项无效")
                    if q["type"]!="multiple" and len(selected)>1:fail(422,"单选或判断只能选一项")
                correct=grade_question(q,selected)
                # A UUID cannot be reused under another account to claim a shared record.
                conn.execute("INSERT INTO records(id,user_id,client_uuid,question_id,payload_hash,selected,correct,duration_seconds,answered_at,received_at,question_snapshot) VALUES(?,?,?,?,?,?,?,?,?,?,?)", (uid(), user["id"], client_id, q["id"], payload_hash, canonical(ordered), int(correct), int(duration), normalized["answered_at"], iso(),canonical(q)))
                result["accepted"] += 1
                touched.add(q["id"])
            result["results"].append({"client_uuid": client_id, "correct": correct, "answer": q["answer"], "explanation": q["explanation"]})
        # Offline devices can upload out of order. Derive the consecutive streak from
        # answer time rather than network arrival order, keeping multi-device state stable.
        for question_id in touched:
            history=rows(conn,"SELECT correct,answered_at FROM records WHERE user_id=? AND question_id=? ORDER BY answered_at DESC,id DESC",(user["id"],question_id))
            errors=[x for x in history if not x["correct"]]
            if not errors:continue
            streak=0
            for past in history:
                if not past["correct"]:break
                streak+=1
            conn.execute("INSERT INTO wrong VALUES(?,?,?,?,?,?) ON CONFLICT(user_id,question_id) DO UPDATE SET error_count=excluded.error_count,last_error_at=excluded.last_error_at,correct_streak=excluded.correct_streak,active=excluded.active",(user["id"],question_id,len(errors),errors[0]["answered_at"],streak,int(streak<cfg["wrong_remove_streak"])))
    return result


@app.get("/api/student/marks")
def get_marks(kind: str = "favorite", user=Depends(student)):
    if kind not in ("favorite", "doubt"):
        fail(422, "标记类型无效")
    with db() as conn:
        _, bank = student_questions(conn,user)
        active_ids = {question["id"] for question in bank}
        return [r[0] for r in conn.execute("SELECT question_id FROM marks WHERE user_id=? AND kind=? AND active=1", (user["id"], kind)) if r[0] in active_ids]


@app.put("/api/student/marks/{question_id}")
def mark_question(question_id: str, data: dict = Body(...), user=Depends(student)):
    kind = data.get("kind")
    if kind not in ("favorite", "doubt") or not isinstance(data.get("active"), bool):
        fail(422, "标记格式无效")
    try:
        updated = datetime.fromisoformat(str(data.get("updated_at", "")).replace("Z", "+00:00"))
        if updated.tzinfo is None or updated > now()+timedelta(minutes=5):
            raise ValueError()
        stamp = iso(updated.astimezone(timezone.utc))
    except ValueError:
        fail(422, "标记时间无效")
    with db() as conn:
        _, questions = student_questions(conn,user)
        if question_id not in {q["id"] for q in questions}:
            # Old offline queues may clear a withdrawn mark, but cannot add new
            # favorites or cross the student's current subject boundary.
            original = one(conn,"SELECT subject_id FROM questions WHERE id=?",(question_id,))
            if data["active"] or not original or original["subject_id"] not in allowed_subjects(conn,user):
                fail(404,"题目不存在")
        conn.execute("INSERT INTO marks VALUES(?,?,?,?,?) ON CONFLICT(user_id,question_id,kind) DO UPDATE SET active=excluded.active,updated_at=excluded.updated_at WHERE excluded.updated_at>marks.updated_at", (user["id"], question_id, kind, int(data["active"]), stamp))
    return {"ok": True}


@app.get("/api/student/wrong")
def wrong_questions(user=Depends(student)):
    with db() as conn:
        _, questions = student_questions(conn,user)
        mistakes = {q["question_id"]: q for q in rows(conn, "SELECT * FROM wrong WHERE user_id=? AND active=1", (user["id"],))}
        return [{**q, "error_count": mistakes[q["id"]]["error_count"], "last_error_at": mistakes[q["id"]]["last_error_at"]} for q in questions if q["id"] in mistakes]


@app.get("/api/student/classes")
def student_classes(user=Depends(student)):
    with db() as conn:
        return classes_for_student(conn,user)


@app.post("/api/student/classes/{class_id}/confirm")
def confirm_class(class_id: str, data: dict = Body(...), user=Depends(student)):
    if data.get("accepted") is not True:
        fail(422, "请确认教师可见范围")
    name = str(data.get("class_name", "")).strip()
    if not 1 <= len(name) <= 50:
        fail(422, "班内姓名必填，最长50字")
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        item = one(conn,"SELECT m.*,c.approval_required,c.archived,c.deleted_at class_deleted_at FROM memberships m JOIN classes c ON c.id=m.class_id WHERE m.class_id=? AND m.user_id=?", (class_id,user["id"]))
        if not item or item["status"] not in ("pending_confirmation", "pending_approval") or item["archived"] or item["class_deleted_at"]:
            fail(409,"无可确认入班申请")
        status = "pending_approval" if item["approval_required"] else "active"
        conn.execute("UPDATE memberships SET status=?,visibility_accepted=1,class_name=? WHERE id=?", (status,name,item["id"]))
        audit(conn,user["id"],"membership.confirm",class_id)
    return {"ok":True,"status":status}


@app.post("/api/student/classes/{class_id}/leave")
def leave_class(class_id: str, user=Depends(student)):
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        if not one(conn,"SELECT id FROM classes WHERE id=? AND deleted_at IS NULL",(class_id,)):
            fail(404,"班级不存在或已删除")
        result=conn.execute("UPDATE memberships SET status='left' WHERE class_id=? AND user_id=? AND status NOT IN ('left','rejected')",(class_id,user["id"]))
        if not result.rowcount:
            fail(404,"班级关系不存在")
        audit(conn,user["id"],"membership.leave",class_id)
    return {"ok":True}


@app.post("/api/student/feedback")
def feedback(data: dict=Body(...),user=Depends(student)):
    content=str(data.get("content", "")).strip()
    kind=data.get("kind","feedback")
    if kind not in ("feedback","question") or not 3<=len(content)<=2000:
        fail(422,"反馈内容须为3至2000字")
    with db() as conn:
        question_id=data.get("question_id")
        if question_id:
            identifier(question_id)
            _,bank=student_questions(conn,user)
            if question_id not in {q["id"] for q in bank}:
                fail(404,"题目不存在")
        tid=uid()
        conn.execute("INSERT INTO tickets(id,user_id,kind,question_id,content,created_at) VALUES(?,?,?,?,?,?)",(tid,user["id"],kind,question_id,content,iso()))
        return one(conn,"SELECT * FROM tickets WHERE id=?",(tid,))


@app.get("/api/student/deletion")
def get_deletion(user=Depends(auth)):
    if user["role"]!="student":fail(403,"仅学生可申请")
    with db() as conn:
        return one(conn,"SELECT status,execute_at FROM deletions WHERE user_id=?",(user["id"],)) or {"status":"none","execute_at":None}


@app.post("/api/student/deletion")
def request_deletion(data:dict=Body(...),user=Depends(student)):
    if data.get("confirm") is not True:fail(422,"请再次确认注销")
    with db() as conn:
        stamp=iso(now()+timedelta(days=settings(conn)["deletion_cooling_days"]))
        existing=one(conn,"SELECT * FROM deletions WHERE user_id=? AND status='pending'",(user["id"],))
        if existing:return {"status":"pending","execute_at":existing["execute_at"]}
        conn.execute("INSERT INTO deletions(user_id,status,requested_at,execute_at) VALUES(?,'pending',?,?) ON CONFLICT(user_id) DO UPDATE SET status='pending',requested_at=excluded.requested_at,execute_at=excluded.execute_at,executed_at=NULL",(user["id"],iso(),stamp))
        audit(conn,user["id"],"user.deletion.requested",user["id"])
        return {"status":"pending","execute_at":stamp}


@app.delete("/api/student/deletion")
def cancel_deletion(user=Depends(auth)):
    if user["role"]!="student":fail(403,"仅学生可操作")
    with db() as conn:
        conn.execute("UPDATE deletions SET status='cancelled' WHERE user_id=? AND status='pending' AND execute_at>?",(user["id"],iso()))
        audit(conn,user["id"],"user.deletion.cancelled",user["id"])
    return {"ok":True}


@app.get("/api/bank/version")
def bank_version(user=Depends(student)):
    with db() as conn:
        version,bank=student_questions(conn,user)
        return {"version":version,"subjects":[{"id":s["id"],"name":s["name"],"count":sum(q["subject_id"]==s["id"] for q in bank)} for s in subject_stats(conn,user)]}


@app.get("/api/bank/package")
def bank_package(request:Request,subject_id:str,user=Depends(student)):
    with db() as conn:
        if subject_id not in allowed_subjects(conn,user):fail(403,"该科目不属于当前科目组")
        version,bank=student_questions(conn,user,subject_id)
        require_media_capability(request,bank)
        return {"version":version,"subject_id":subject_id,"questions":bank,"checksum":hashlib.sha256(canonical(bank).encode()).hexdigest(),"checksum_algorithm":"sha256","canonical":"json-sort-keys-utf8-compact"}


@app.get("/api/management/dashboard")
def management_dashboard(user=Depends(manager)):
    with db() as conn:
        if user["role"]=="admin":
            counts={k:conn.execute("SELECT COUNT(*) FROM "+table+where,args).fetchone()[0] for k,table,where,args in (("students","users"," WHERE role='student' AND deleted_at IS NULL",()),("teachers","users"," WHERE role='teacher' AND deleted_at IS NULL",()),("classes","classes"," WHERE deleted_at IS NULL",()),("questions","questions"," WHERE status<>'deleted'",()),("pending_tickets","tickets"," WHERE status='open'",()),("pending_reviews","questions"," WHERE status='pending'",()))}
            agg=one(conn,"SELECT COUNT(*) answered,COALESCE(SUM(correct),0) correct FROM records")
            activity=rows(conn,"SELECT substr(answered_at,1,10) date,COUNT(*) answered,SUM(correct) correct FROM records GROUP BY date ORDER BY date DESC LIMIT 14")
            recent=rows(conn,"SELECT action,target,created_at FROM audit ORDER BY created_at DESC LIMIT 8")
        else:
            # Teacher dashboards expose class membership counts, never students' private practice analytics.
            counts={"students":conn.execute("SELECT COUNT(DISTINCT m.user_id) FROM memberships m JOIN classes c ON c.id=m.class_id JOIN users u ON u.id=m.user_id WHERE c.teacher_id=? AND m.status='active' AND (m.visibility_accepted=1 OR (m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL)) AND c.archived=0 AND c.deleted_at IS NULL AND u.enabled=1 AND u.deleted_at IS NULL",(user["id"],)).fetchone()[0],"teachers":1,"classes":conn.execute("SELECT COUNT(*) FROM classes WHERE teacher_id=? AND deleted_at IS NULL",(user["id"],)).fetchone()[0],"questions":0,"pending_tickets":0,"pending_reviews":0}
            agg={"answered":0,"correct":0};activity=[];recent=[]
        return {"stats":{**counts,"answered":agg["answered"],"accuracy":round(agg["correct"]*100/agg["answered"],1) if agg["answered"] else 0},"activity":activity,"recent_activity":recent}


@app.get("/api/management/users")
def list_users(role:str|None=None,q:str="",deleted:bool=False,limit:int=Query(1000,ge=1,le=1000),user=Depends(manager)):
    if deleted and user["role"]!="admin":fail(403,"仅管理员可查看已删除账号")
    with db() as conn:
        sql="SELECT DISTINCT u.* FROM users u"
        args=[]
        if user["role"]=="teacher":
            sql+=" JOIN memberships m ON m.user_id=u.id JOIN classes c ON c.id=m.class_id WHERE c.teacher_id=? AND m.status IN ('active','pending_confirmation','pending_approval') AND u.role='student' AND c.archived=0 AND c.deleted_at IS NULL"
            args.append(user["id"])
        else:sql+=" WHERE 1=1"
        sql+=" AND "+("u.deleted_at IS NOT NULL AND u.password_hash<>'' AND EXISTS(SELECT 1 FROM admin_user_deletions d WHERE d.user_id=u.id AND d.deleted_at=u.deleted_at)" if deleted else "u.deleted_at IS NULL")
        if role:sql+=" AND u.role=?";args.append(role)
        if q:sql+=" AND (u.username LIKE ? OR u.name LIKE ?)";args.extend(["%"+q[:100]+"%"]*2)
        sql+=" ORDER BY u.created_at DESC LIMIT ?";args.append(limit)
        audit(conn,user["id"],"users.list",role or "all")
        return [((roster_user(r) if user["role"]=="teacher" else public_user(r)) | ({"deleted_at":r["deleted_at"],"can_restore":True} if deleted else {})) for r in rows(conn,sql,args)]


def add_to_class(conn,class_id,user_id,actor):
    classroom=class_scope(conn,class_id,actor,True)
    identifier(user_id)
    target=one(conn,"SELECT * FROM users WHERE id=? AND role='student' AND deleted_at IS NULL",(user_id,))
    if not target:fail(404,"学生不存在")
    from .professions import ensure_class_profession
    ensure_class_profession(conn,sys.modules[__name__],classroom,target)
    existing=one(conn,"SELECT * FROM memberships WHERE class_id=? AND user_id=?",(class_id,user_id))
    if existing and existing["status"] not in ("left","rejected"):fail(409,"学生已在班级或待确认")
    # School administration can enroll directly; this is not student consent.
    # Re-addition starts a fresh enrollment and clears any previous exemption.
    direct = actor["role"] == "admin"
    stamp = iso()
    conn.execute("INSERT INTO memberships(id,class_id,user_id,status,visibility_accepted,class_name,created_at,admin_enrolled_by,admin_enrolled_at) VALUES(?,?,?,?,0,?,?,?,?) ON CONFLICT(class_id,user_id) DO UPDATE SET status=excluded.status,visibility_accepted=0,class_name=excluded.class_name,created_at=excluded.created_at,admin_enrolled_by=excluded.admin_enrolled_by,admin_enrolled_at=excluded.admin_enrolled_at",(uid(),class_id,user_id,"active" if direct else "pending_confirmation",target["name"] if direct else "",stamp,actor["id"] if direct else None,stamp if direct else None))
    if direct:
        membership = one(conn,"SELECT id FROM memberships WHERE class_id=? AND user_id=?",(class_id,user_id))
        audit(conn,actor["id"],"membership.admin_enroll",membership["id"],"管理员直接入班")


@app.post("/api/management/users")
def add_user(data:dict=Body(...),user=Depends(manager)):
    role=data.get("role","student")
    with db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        profession = data.get('subject_group_id')
        if profession is not None:
            if role != 'student':fail(422,'仅学生账号需要专业')
            from .professions import ensure_enabled_group
            ensure_enabled_group(conn,sys.modules[__name__],profession)
        if user["role"]=="teacher":
            if role!="student" or not data.get("class_id"):fail(403,"教师只能向自己的班级创建学生")
            classroom=class_scope(conn,data["class_id"],user,True)
            if profession is not None and profession!=classroom['subject_group_id']:
                fail(403,'教师只能按所选班级的专业开通学生')
        target=create_user(conn,data.get("username"),data.get("name"),role,data.get("password"),True,role!="student")
        if profession is not None:
            conn.execute('UPDATE users SET subject_group_id=? WHERE id=?',(profession,target['id']))
        if data.get("class_id"):add_to_class(conn,data["class_id"],target["id"],user)
        audit(conn,user["id"],"user.create",target["id"])
        return public_user(one(conn,'SELECT * FROM users WHERE id=?',(target['id'],)))


@app.patch("/api/management/users/{user_id}")
def update_user(user_id:str,data:dict=Body(...),user=Depends(manager)):
    with db() as conn:
        target=user_scope(conn,user_id,user,True)
        from .user_profiles import update_profile
        return update_profile(conn,sys.modules[__name__],user,target,data)


@app.post("/api/management/users/{user_id}/reset-password")
def reset_password(user_id:str,data:dict=Body(...),user=Depends(manager)):
    hashed=password_hash(data.get("password"))
    with db() as conn:
        user_scope(conn,user_id,user,True)
        conn.execute("UPDATE users SET password_hash=?,must_change_password=1 WHERE id=?",(hashed,user_id))
        conn.execute("UPDATE sessions SET revoked=1 WHERE user_id=?",(user_id,))
        audit(conn,user["id"],"user.password.reset",user_id)
    return {"ok":True}


@app.post("/api/management/users/import")
def import_users(data:dict=Body(...),user=Depends(manager)):
    incoming=data.get("rows")
    if not isinstance(incoming,list) or not 1<=len(incoming)<=500:fail(422,"导入行数须为1至500")
    errors=[];seen=set()
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        class_id=data.get("class_id")
        if user["role"]=="teacher" and not class_id:fail(403,"教师导入须指定自己的班级")
        if class_id:class_scope(conn,class_id,user,True)
        for i,item in enumerate(incoming,1):
            if not isinstance(item,dict):errors.append({"row":i,"message":"行格式无效"});continue
            username=item.get("username")
            if not isinstance(username,str) or not re.fullmatch(r"[A-Za-z0-9_.@-]{3,64}",username):errors.append({"row":i,"message":"学号或账号格式错误"})
            elif username in seen or one(conn,"SELECT id FROM users WHERE username=?",(username,)):errors.append({"row":i,"message":"学号或账号重复"})
            seen.add(username if isinstance(username,str) else "")
            if not isinstance(item.get("name"),str) or not 1<=len(item["name"].strip())<=50:errors.append({"row":i,"message":"姓名必填且最长50字"})
            try:password_hash(item.get("password"))
            except HTTPException as exc:errors.append({"row":i,"message":exc.detail})
        if errors:return {"created":0,"errors":errors}
        for item in incoming:
            target=create_user(conn,item["username"],item["name"],"student",item["password"])
            if class_id:add_to_class(conn,class_id,target["id"],user)
        audit(conn,user["id"],"users.import",class_id or "all",str(len(incoming))+" students")
    return {"created":len(incoming),"errors":[]}


@app.get("/api/management/classes")
def list_classes(deleted:bool=False,user=Depends(manager)):
    if deleted and user["role"]!="admin":fail(403,"仅管理员可查看已删除班级")
    with db() as conn:
        member_filter=" AND s.enabled=1 AND (m.visibility_accepted=1 OR (m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL))" if user['role']=='teacher' else ''
        query="SELECT c.*,u.name teacher_name,(SELECT COUNT(*) FROM memberships m JOIN users s ON s.id=m.user_id WHERE m.class_id=c.id AND m.status='active' AND s.deleted_at IS NULL"+member_filter+") member_count,(SELECT COUNT(*) FROM memberships m JOIN users s ON s.id=m.user_id WHERE m.class_id=c.id AND m.status IN ('pending_confirmation','pending_approval') AND s.deleted_at IS NULL) pending_count FROM classes c JOIN users u ON u.id=c.teacher_id WHERE c.deleted_at IS "+("NOT NULL" if deleted else "NULL")
        result=rows(conn,query+(" AND c.teacher_id=?" if user["role"]=="teacher" else "")+" ORDER BY c.created_at DESC",(user["id"],) if user["role"]=="teacher" else ())
        if deleted:
            for item in result:
                item["can_restore"]=bool(one(conn,"SELECT u.id FROM users u JOIN groups g ON g.id=? WHERE u.id=? AND u.role='teacher' AND u.enabled=1 AND u.deleted_at IS NULL AND g.enabled=1",(item["subject_group_id"],item["teacher_id"])))
        return result


@app.post("/api/management/classes")
def add_class(data:dict=Body(...),user=Depends(manager)):
    name=str(data.get("name","")).strip();term=str(data.get("term","")).strip()
    if not 1<=len(name)<=80 or not 1<=len(term)<=60:fail(422,"班级名称和学期必填")
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        teacher_id=data.get("teacher_id",user["id"])
        if user["role"]=="teacher":teacher_id=user["id"]
        identifier(teacher_id)
        if not one(conn,"SELECT id FROM users WHERE id=? AND role='teacher' AND enabled=1 AND deleted_at IS NULL",(teacher_id,)):fail(422,"请选择有效教师")
        if not one(conn,"SELECT id FROM groups WHERE id=? AND enabled=1",(identifier(data.get("subject_group_id")),)):fail(422,"科目组不存在或已停用")
        cid=uid()
        conn.execute("INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,approval_required,created_at) VALUES(?,?,?,?,?,?,?,?)",(cid,name,teacher_id,data["subject_group_id"],term,secrets.token_hex(4).upper(),int(bool(data.get("approval_required",False))),iso()))
        audit(conn,user["id"],"class.create",cid)
        return one(conn,"SELECT * FROM classes WHERE id=?",(cid,))


@app.patch("/api/management/classes/{class_id}")
def update_class(class_id:str,data:dict=Body(...),user=Depends(manager)):
    if set(data)-{"name","archived","reset_invite","approval_required"}:fail(422,"不支持的班级字段")
    with db() as conn:
        cls=class_scope(conn,class_id,user,True)
        for key in ("name","archived","approval_required"):
            if key not in data:continue
            value=data[key]
            if key=="name":
                if not isinstance(value,str) or not 1<=len(value.strip())<=80:fail(422,"名称无效")
                value=value.strip()
            elif not isinstance(value,bool):fail(422,"状态无效")
            conn.execute("UPDATE classes SET "+key+"=? WHERE id=?",(value,class_id))
        if data.get("reset_invite"):conn.execute("UPDATE classes SET invite_code=? WHERE id=?",(secrets.token_hex(4).upper(),class_id))
        audit(conn,user["id"],"class.update",class_id)
        return one(conn,"SELECT * FROM classes WHERE id=?",(class_id,))


@app.get("/api/management/classes/{class_id}/members")
def members(class_id:str,user=Depends(manager)):
    with db() as conn:
        class_scope(conn,class_id,user)
        teacher_filter=" AND m.status IN ('active','pending_confirmation','pending_approval')" if user['role']=='teacher' else ''
        values=rows(conn,"SELECT u.*,m.id membership_id,m.status,m.class_name,m.visibility_accepted,(m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL) admin_enrolled FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.class_id=? AND u.deleted_at IS NULL"+teacher_filter+" ORDER BY m.created_at",(class_id,))
        audit(conn,user["id"],"class.members.view",class_id)
        return [{**(roster_user(r) if user["role"]=="teacher" else public_user(r)),"membership_id":r["membership_id"],"status":r["status"],"class_name":r["class_name"],"visibility_accepted":bool(r["visibility_accepted"]),"admin_enrolled":bool(r["admin_enrolled"]),"enrollment_source":"admin" if r["admin_enrolled"] else "student_confirmation"} for r in values]


@app.post("/api/management/classes/{class_id}/members")
def add_member(class_id:str,data:dict=Body(...),user=Depends(manager)):
    with db() as conn:
        # A teacher may only reassign already owned students; new students use create/import.
        if user["role"]=="teacher":user_scope(conn,data.get("user_id"),user,True)
        add_to_class(conn,class_id,data.get("user_id"),user)
        audit(conn,user["id"],"class.member.add",class_id)
    return {"ok":True}


@app.patch("/api/management/memberships/{membership_id}")
def update_membership(membership_id:str,data:dict=Body(...),user=Depends(manager)):
    status=data.get("status")
    if status not in ("active","rejected","left"):fail(422,"状态无效")
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        item=one(conn,"SELECT * FROM memberships WHERE id=?",(membership_id,))
        if not item:fail(404,"成员不存在")
        class_scope(conn,item["class_id"],user,True)
        if status=="active":
            target=one(conn,"SELECT name FROM users WHERE id=? AND role='student' AND deleted_at IS NULL",(item["user_id"],))
            if not target:fail(404,"学生不存在或已删除")
            if user["role"]=="admin":
                if item["status"] not in ("pending_confirmation","pending_approval"):
                    fail(409,"仅待确认或待审批成员可直接入班")
                conn.execute("UPDATE memberships SET status='active',class_name=CASE WHEN class_name='' THEN ? ELSE class_name END,admin_enrolled_by=?,admin_enrolled_at=? WHERE id=?",(target["name"],user["id"],iso(),membership_id))
                audit(conn,user["id"],"membership.admin_enroll",membership_id,"管理员直接入班")
            else:
                if not item["visibility_accepted"] or item["status"]!="pending_approval":fail(409,"学生须先确认可见范围并进入待审批状态")
                conn.execute("UPDATE memberships SET status='active' WHERE id=?",(membership_id,))
        else:
            conn.execute("UPDATE memberships SET status=? WHERE id=?",(status,membership_id))
        audit(conn,user["id"],"membership."+status,membership_id)
    return {"ok":True}


def validate_question(conn,data):
    required=("subject_id","knowledge_id","type","stem","options","answer","explanation","difficulty","source","authorization")
    if any(k not in data for k in required):fail(422,"题目字段不完整")
    if not all(isinstance(data[k],str) for k in ("subject_id","knowledge_id","type")):fail(422,"科目、知识点与题型须为字符串")
    if not one(conn,"SELECT id FROM knowledge WHERE id=? AND subject_id=?",(data["knowledge_id"],data["subject_id"])):fail(422,"知识点与科目不匹配")
    if data["type"] not in ("single","multiple","judge","fill"):fail(422,"支持单选、多选、判断与填空题")
    if not isinstance(data.get('options'),list):fail(422,"选项格式无效")
    from .question_media import validate_media
    try:
        data['media'] = validate_media(data)
    except ValueError as error:
        fail(422,str(error))
    for key,maxlen in (("stem",12000),("explanation",20000),("source",500),("authorization",1000)):
        if not isinstance(data[key],str) or not 1<=len(data[key].strip())<=maxlen:fail(422,key+"内容必填且长度须合理")
    opts=data["options"];answer=data["answer"]
    if data['type'] == 'fill':
        if opts != []:fail(422,'填空题不应包含选项')
        if not isinstance(answer,list) or not 1<=len(answer)<=20 or not all(isinstance(variants,list) and 1<=len(variants)<=20 and all(isinstance(value,str) and 1<=len(value.strip())<=1000 for value in variants) for variants in answer):
            fail(422,'填空答案须按空位提供可接受答案列表，最多20空')
        if not isinstance(data['difficulty'],int) or isinstance(data['difficulty'],bool) or not 1<=data['difficulty']<=5:fail(422,'难度范围1至5')
        if data.get('status','published') not in ('published','draft','pending'):fail(422,'保存后直接发布；请使用上下线操作调整状态')
        return
    if not isinstance(opts,list) or not 2<=len(opts)<=10 or not all(isinstance(x,dict) and isinstance(x.get("key"),str) and re.fullmatch(r"[A-J]",x["key"]) and isinstance(x.get("text"),str) and 1<=len(x["text"])<=6000 for x in opts):fail(422,"选项格式无效")
    keys=[x["key"] for x in opts]
    if len(set(keys))!=len(keys) or not isinstance(answer,list) or not answer or not all(isinstance(x,str) for x in answer) or len(set(answer))!=len(answer) or not set(answer).issubset(keys):fail(422,"答案须匹配唯一选项")
    if data["type"]!="multiple" and len(answer)!=1:fail(422,"单选或判断须一个答案")
    if data["type"]=="judge" and len(opts)!=2:fail(422,"判断题须两个选项")
    if not isinstance(data["difficulty"],int) or isinstance(data["difficulty"],bool) or not 1<=data["difficulty"]<=5:fail(422,"难度范围1至5")
    if data.get("status","published") not in ("published","draft","pending"):fail(422,"保存后直接发布；请使用上下线操作调整状态")


@app.get("/api/management/questions")
def management_questions(q:str="",status:str|None=None,subject_id:str|None=None,limit:int=Query(5000,ge=1,le=5000),user=Depends(admin)):
    with db() as conn:
        sql="SELECT * FROM questions WHERE "+("status='deleted'" if status=="deleted" else "status<>'deleted'");args=[]
        if q:sql+=" AND stem LIKE ?";args.append("%"+q[:100]+"%")
        if status:sql+=" AND status=?";args.append(status)
        if subject_id:sql+=" AND subject_id=?";args.append(subject_id)
        items=rows(conn,sql+" ORDER BY created_at DESC LIMIT ?",args+[limit])
        version,_=current_bank(conn)
        audit(conn,user["id"],"questions.list")
        return [{**question_public(x,version),**{k:x[k] for k in ("authorization","status","creator_id","reviewer_id","created_at","updated_at")}} for x in items]


@app.post("/api/management/questions")
def add_question(data:dict=Body(...),user=Depends(admin)):
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        from .bank_classification import normalize_question_scope, record_manual_classification
        data=normalize_question_scope(conn,sys.modules[__name__],data)
        validate_question(conn,data)
        qid=uid()
        conn.execute("INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at,media) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",(qid,data["subject_id"],data["knowledge_id"],data["type"],data["stem"],canonical(data["options"]),canonical(data["answer"]),data["explanation"],data["difficulty"],data["source"],data["authorization"],"published",user["id"],None,iso(),iso(),canonical(data.get('media',{}))))
        record_manual_classification(conn,sys.modules[__name__],qid,data['subject_id'],data['knowledge_id'],user['id'])
        audit(conn,user["id"],"question.create",qid)
        release=publish_bank(conn,user["id"])
        return {**question_public(one(conn,"SELECT * FROM questions WHERE id=?",(qid,)),release["version"]),"status":"published","creator_id":user["id"],"release":release}


@app.put("/api/management/questions/{question_id}")
def edit_question(question_id:str,data:dict=Body(...),user=Depends(admin)):
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        previous=one(conn,"SELECT * FROM questions WHERE id=? AND status<>'deleted'",(question_id,))
        if not previous:fail(404,"题目不存在或已移除")
        from .bank_classification import normalize_question_scope, record_manual_classification
        data=normalize_question_scope(conn,sys.modules[__name__],data,previous)
        if 'media' not in data:
            data['media'] = json.loads(previous.get('media') or '{}')
        validate_question(conn,data)
        conn.execute("UPDATE questions SET subject_id=?,knowledge_id=?,type=?,stem=?,options=?,answer=?,explanation=?,difficulty=?,source=?,authorization=?,status='published',creator_id=?,reviewer_id=NULL,updated_at=?,media=? WHERE id=?",(data["subject_id"],data["knowledge_id"],data["type"],data["stem"],canonical(data["options"]),canonical(data["answer"]),data["explanation"],data["difficulty"],data["source"],data["authorization"],user["id"],iso(),canonical(data.get('media',{})),question_id))
        if (previous['subject_id'],previous['knowledge_id'])!=(data['subject_id'],data['knowledge_id']):
            record_manual_classification(conn,sys.modules[__name__],question_id,data['subject_id'],data['knowledge_id'],user['id'])
            audit(conn,user['id'],'question.classify',question_id,previous['subject_id']+' -> '+data['subject_id'])
        audit(conn,user["id"],"question.update",question_id)
        return {"ok":True,"id":question_id,"status":"published",**publish_bank(conn,user["id"])}


@app.post("/api/management/questions/{question_id}/review")
def review_question(question_id:str,data:dict=Body(...),user=Depends(admin)):
    fail(410,"题库审核步骤已取消，管理员保存或导入后直接发布")


@app.post("/api/management/bank/publish")
def publish(user=Depends(admin)):
    with db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        for item in rows(conn,"SELECT * FROM questions WHERE status IN ('draft','pending')"):
            validate_question(conn,{**question_public(item),"authorization":item["authorization"],"status":"published"})
        changed=conn.execute("UPDATE questions SET status='published',reviewer_id=NULL,updated_at=? WHERE status IN ('draft','pending')",(iso(),)).rowcount
        return {**publish_bank(conn,user["id"]),"changed":changed}


@app.get("/api/management/groups")
def get_groups(user=Depends(manager)):
    with db() as conn:
        return [{**r,"enabled":bool(r["enabled"]),"subject_ids":json.loads(r["subject_ids"])} for r in rows(conn,"SELECT * FROM groups")]


def validate_group(conn,data):
    if not isinstance(data.get("name"),str) or not 1<=len(data["name"].strip())<=80:fail(422,"科目组名称无效")
    if not isinstance(data.get("enabled",True),bool):fail(422,"启用状态无效")
    subjects=data.get("subject_ids",[])
    if not isinstance(subjects,list) or not all(isinstance(x,str) for x in subjects) or len(set(subjects))!=len(subjects):fail(422,"关联科目无效")
    if data.get('enabled',True) and not subjects:fail(422,'启用专业前请至少配置一个真实科目')
    if any(not one(conn,"SELECT id FROM subjects WHERE id=?",(x,)) for x in subjects):fail(422,"关联科目不存在")


@app.post("/api/management/groups")
def add_group(data:dict=Body(...),user=Depends(admin)):
    if set(data)-{'name','enabled','subject_ids'}:fail(422,'不支持的专业字段')
    with db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        validate_group(conn,data)
        if one(conn,"SELECT id FROM groups WHERE name=?",(data["name"].strip(),)):fail(409,"科目组名称已存在")
        gid=uid();conn.execute("INSERT INTO groups VALUES(?,?,?,?)",(gid,data["name"].strip(),int(data.get("enabled",True)),canonical(data.get("subject_ids",[]))))
        audit(conn,user["id"],"group.create",gid)
        return {"id":gid,**data}


@app.patch("/api/management/groups/{group_id}")
def edit_group(group_id:str,data:dict=Body(...),user=Depends(admin)):
    if set(data)-{"name","enabled","subject_ids"}:fail(422,"不支持的科目组字段")
    with db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        old=one(conn,"SELECT * FROM groups WHERE id=?",(group_id,))
        if not old:fail(404,"科目组不存在")
        merged={**old,"enabled":bool(old["enabled"]),"subject_ids":json.loads(old["subject_ids"]),**data}
        validate_group(conn,merged)
        if one(conn,"SELECT id FROM groups WHERE name=? AND id<>?",(merged["name"].strip(),group_id)):fail(409,"科目组名称已存在")
        referenced=conn.execute("SELECT COUNT(*) FROM users WHERE subject_group_id=? AND deleted_at IS NULL",(group_id,)).fetchone()[0]+conn.execute("SELECT COUNT(*) FROM classes WHERE subject_group_id=? AND deleted_at IS NULL",(group_id,)).fetchone()[0]
        removed=set(json.loads(old["subject_ids"]))-set(merged["subject_ids"])
        if referenced and removed:fail(409,"科目组已有学生或班级引用，不能移除关联科目；可停用并保留历史")
        if old['enabled'] and not merged['enabled']:
            from .professions import group_usage
            usage=group_usage(conn,sys.modules[__name__],group_id)
            if usage['active_student_count'] or usage['active_class_count']:
                fail(409,f"该专业仍关联{usage['active_student_count']}名启用学生、{usage['active_class_count']}个未归档班级，请先处理关联再停用；历史数据会保留")
        conn.execute("UPDATE groups SET name=?,enabled=?,subject_ids=? WHERE id=?",(merged["name"].strip(),int(merged["enabled"]),canonical(merged["subject_ids"]),group_id))
        audit(conn,user["id"],"group.update",group_id)
        return {"id":group_id,"name":merged["name"],"enabled":merged["enabled"],"subject_ids":merged["subject_ids"]}


@app.get("/api/management/subjects")
def management_subjects(user=Depends(manager)):
    with db() as conn:return rows(conn,"SELECT * FROM subjects")


@app.post("/api/management/subjects")
def add_subject(data:dict=Body(...),user=Depends(admin)):
    name=data.get("name");score=data.get("full_score",100);duration=data.get("duration_minutes",60)
    if not isinstance(name,str) or not 1<=len(name.strip())<=100 or not isinstance(score,int) or not 1<=score<=1000 or not isinstance(duration,int) or not 1<=duration<=600:fail(422,"科目名称、分值或时长无效")
    with db() as conn:
        conn.execute('BEGIN IMMEDIATE')
        from .bank_classification import normalized_subject_name
        name=normalized_subject_name(sys.modules[__name__],name)
        if any(normalized_subject_name(sys.modules[__name__],row['name']).casefold()==name.casefold() for row in rows(conn,'SELECT name FROM subjects')):fail(409,'科目名称已存在')
        group=one(conn,"SELECT * FROM groups WHERE id=? AND enabled=1",(identifier(data.get("group_id")),))
        if not group:fail(422,"请选择启用科目组")
        sid=uid();conn.execute("INSERT INTO subjects VALUES(?,?,?,?,?)",(sid,name.strip(),group["id"],score,duration))
        ids=json.loads(group["subject_ids"])+[sid];conn.execute("UPDATE groups SET subject_ids=? WHERE id=?",(canonical(ids),group["id"]))
        audit(conn,user["id"],"subject.create",sid)
        return one(conn,"SELECT * FROM subjects WHERE id=?",(sid,))


@app.get("/api/management/knowledge")
def management_knowledge(user=Depends(manager)):
    with db() as conn:return rows(conn,"SELECT * FROM knowledge")


@app.post("/api/management/knowledge")
def add_knowledge(data:dict=Body(...),user=Depends(admin)):
    name=data.get("name")
    if not isinstance(name,str) or not 1<=len(name.strip())<=100:fail(422,"知识点名称无效")
    with db() as conn:
        if not one(conn,"SELECT id FROM subjects WHERE id=?",(identifier(data.get("subject_id")),)):fail(422,"科目不存在")
        parent=data.get("parent_id") or None
        if parent:identifier(parent)
        if parent and not one(conn,"SELECT id FROM knowledge WHERE id=? AND subject_id=?",(parent,data["subject_id"])):fail(422,"父节点须属于同一科目")
        kid=uid();conn.execute("INSERT INTO knowledge VALUES(?,?,?,?)",(kid,name.strip(),data["subject_id"],parent))
        audit(conn,user["id"],"knowledge.create",kid)
        return one(conn,"SELECT * FROM knowledge WHERE id=?",(kid,))


@app.get("/api/management/tickets")
def tickets(user=Depends(admin)):
    with db() as conn:
        audit(conn,user["id"],"tickets.list")
        return rows(conn,"SELECT t.*,u.username FROM tickets t JOIN users u ON u.id=t.user_id ORDER BY t.created_at DESC LIMIT 1000")


@app.patch("/api/management/tickets/{ticket_id}")
def update_ticket(ticket_id:str,data:dict=Body(...),user=Depends(admin)):
    if data.get("status") not in ("open","processing","resolved","closed"):fail(422,"工单状态无效")
    reply=data.get("reply","")
    if not isinstance(reply,str) or len(reply)>2000:fail(422,"回复最长2000字")
    with db() as conn:
        if not one(conn,"SELECT id FROM tickets WHERE id=?",(ticket_id,)):fail(404,"工单不存在")
        conn.execute("UPDATE tickets SET status=?,reply=? WHERE id=?",(data["status"],reply,ticket_id));audit(conn,user["id"],"ticket.update",ticket_id)
        return one(conn,"SELECT * FROM tickets WHERE id=?",(ticket_id,))


@app.get("/api/management/audit")
def audits(user=Depends(admin)):
    with db() as conn:
        audit(conn,user["id"],"audit.view")
        return rows(conn,"SELECT a.*,COALESCE(u.name,a.actor) actor_name FROM audit a LEFT JOIN users u ON u.id=a.actor ORDER BY a.created_at DESC LIMIT 1000")


@app.get("/api/management/settings")
def get_settings(user=Depends(admin)):
    with db() as conn:return settings(conn)


@app.patch("/api/management/settings")
def update_settings(data:dict=Body(...),user=Depends(admin)):
    if not data or set(data)-set(DEFAULT_SETTINGS):fail(422,"包含不支持的系统参数")
    ints={"current_year":(now().year,now().year+10),"device_limit":(1,10),"deletion_cooling_days":(1,30),"wrong_remove_streak":(1,10),"today_goal":(1,500),"access_token_minutes":(5,120),"refresh_token_days":(1,90),"login_failure_limit":(3,20),"login_lock_seconds":(30,3600),"audit_retention_days":(30,3650),"backup_retention_days":(1,365)}
    for key,value in data.items():
        if key in ints:
            lo,hi=ints[key]
            if not isinstance(value,int) or isinstance(value,bool) or not lo<=value<=hi:fail(422,key+"数值超出范围")
        elif not isinstance(value,str) or len(value)>2000:fail(422,key+"格式无效")
        elif key in ("exam_start","exam_end"):
            try:datetime.strptime(value,"%Y-%m-%d")
            except ValueError:fail(422,"考试日期须为YYYY-MM-DD")
        elif key=="multiple_rule" and value!="all_or_nothing":fail(422,"M1仅支持全对得分")
        elif key=="app_download_url" and value and not value.startswith("https://"):fail(422,"下载地址须使用HTTPS")
        elif key=="agreement_version" and not value.strip():fail(422,"协议版本不能为空")
    with db() as conn:
        merged={**settings(conn),**data}
        if merged["exam_end"]<merged["exam_start"]:fail(422,"考试结束日期不能早于开始日期")
        for key,value in data.items():conn.execute("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(key,canonical(value)))
        audit(conn,user["id"],"settings.update",",".join(sorted(data)))
        return settings(conn)


@app.get("/api/management/deletions")
def list_deletions(user=Depends(admin)):
    with db() as conn:
        audit(conn,user["id"],"deletions.list")
        return rows(conn,"SELECT d.*,u.username,u.name FROM deletions d JOIN users u ON u.id=d.user_id ORDER BY d.requested_at DESC")


@app.post("/api/management/deletions/execute")
def run_deletions(user=Depends(admin)):
    with db() as conn:return {"executed":execute_deletions(conn)}


@app.get("/api/management/announcements")
def get_announcements(user=Depends(manager)):
    with db() as conn:return rows(conn,"SELECT id,title,content,created_at FROM announcements ORDER BY created_at DESC LIMIT 100")


@app.post("/api/management/announcements")
def add_announcement(data:dict=Body(...),user=Depends(admin)):
    title=data.get("title");content=data.get("content")
    if not isinstance(title,str) or not 1<=len(title.strip())<=100 or not isinstance(content,str) or not 1<=len(content.strip())<=5000:fail(422,"公告标题和内容必填")
    with db() as conn:
        aid=uid();conn.execute("INSERT INTO announcements VALUES(?,?,?,?,?)",(aid,title.strip(),content.strip(),user["id"],iso()));audit(conn,user["id"],"announcement.create",aid)
        return one(conn,"SELECT * FROM announcements WHERE id=?",(aid,))


# Additional import/export and audited detail operations are kept separate.
import sys
from .m1_extensions import register_extensions
register_extensions(app, sys.modules[__name__])
from .word_import import register_word_import
register_word_import(app, sys.modules[__name__])
from .teaching import register_teaching
register_teaching(app, sys.modules[__name__])
from .admin_deletion import register_admin_deletion
register_admin_deletion(app, sys.modules[__name__])
from .bank_management import register_bank_management
register_bank_management(app, sys.modules[__name__])
from .bank_classification import register_bank_classification
register_bank_classification(app, sys.modules[__name__])
from .bank_pagination import register_bank_pagination
register_bank_pagination(app, sys.modules[__name__])
from .student_analytics import register_student_analytics
register_student_analytics(app, sys.modules[__name__])
from .user_profiles import register_user_profiles
register_user_profiles(app, sys.modules[__name__])
from .student_overview import register_student_overview
register_student_overview(app, sys.modules[__name__])
from .teacher_analytics import register_teacher_analytics
register_teacher_analytics(app, sys.modules[__name__])
from .practice_stream import register_practice_stream
register_practice_stream(app, sys.modules[__name__])
from .professions import register_professions
register_professions(app, sys.modules[__name__])
app.add_middleware(BoundedBodyMiddleware)
