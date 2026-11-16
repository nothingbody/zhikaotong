let accessToken = '';
let refreshPromise = null;
let sessionVersion = 0;
const REFRESH_KEY = 'zhikaotong_refresh';
export function hasSession() { return Boolean(sessionStorage.getItem(REFRESH_KEY)); }
export function storeSession(data, rotation = false) {
  if (!rotation) sessionVersion += 1;
  accessToken = data.access_token;
  sessionStorage.setItem(REFRESH_KEY, data.refresh_token);
}
export function clearSession() { sessionVersion += 1; accessToken = ''; sessionStorage.removeItem(REFRESH_KEY); }
export function getRefreshToken() { return sessionStorage.getItem(REFRESH_KEY); }
export async function api(path, options = {}, retry = true) {
  const requestVersion = sessionVersion;
  const {responseType, ...requestOptions} = options;
  const headers = { ...requestOptions.headers };
  if (options.body !== undefined) headers['Content-Type'] = 'application/json';
  if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
  let response;
  try { response = await fetch(`/api${path}`, { ...requestOptions, headers, body: options.body === undefined ? undefined : JSON.stringify(options.body) }); }
  catch { throw new Error('连接服务失败，请检查网络或服务是否启动。'); }
  if (response.status === 401 && retry && getRefreshToken() && path !== '/auth/refresh' && path !== '/auth/login') {
    if (requestVersion !== sessionVersion) throw new Error('登录状态已变更，请重新操作。');
    if (!refreshPromise) refreshPromise = api('/auth/refresh', {method: 'POST', body: { refresh_token: getRefreshToken() }}, false).then(data => {
      if (requestVersion !== sessionVersion) throw new Error('登录状态已变更。');
      storeSession(data, true);
    }).finally(() => { refreshPromise = null; });
    try { await refreshPromise; return api(path, options, false); }
    catch {
      if (requestVersion === sessionVersion) { clearSession(); window.dispatchEvent(new Event('session-expired')); }
      throw new Error('登录状态已变更或已过期，请重新登录。');
    }
  }
  if (response.ok && responseType === 'blob') {
    if (requestVersion !== sessionVersion) throw new Error('登录状态已变更，请重新操作。');
    const data = await response.blob();
    if (requestVersion !== sessionVersion) throw new Error('登录状态已变更，请重新操作。');
    return data;
  }
  let data;
  try { data = await response.json(); } catch { data = {}; }
  if (!response.ok) {
    const detail = data.detail;
    const message = Array.isArray(detail) ? detail.map(item => `${item.loc?.slice(1).join('.') || ''} ${item.msg || item.message || ''}`).join('；') : typeof detail === 'string' ? detail : detail?.message || '请求未完成，请稍后重试。';
    const error = new Error(message); error.status = response.status; error.data = data; throw error;
  }
  return data;
}
export const apiBlob = (path, options = {}) => api(path, {...options, responseType: 'blob'});
export const post = (path, body = {}) => api(path, { method: 'POST', body });
export const patch = (path, body) => api(path, { method: 'PATCH', body });
export const put = (path, body) => api(path, { method: 'PUT', body });
