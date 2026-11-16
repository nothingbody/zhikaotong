export const IMAGE_TOKEN = /\{\{img:([a-f0-9]{64})\}\}/g;
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
const checks = new Map();

export function plainQuestionText(value) {
  return String(value ?? '').replace(/\{\{img:[^}]*\}\}/g, '〔题图〕');
}

export function editableQuestionText(value) {
  let number = 0;
  return String(value ?? '').replace(IMAGE_TOKEN, () => `〔原图${++number}〕`);
}

export function restoreQuestionText(value, original) {
  const tokens = [...String(original ?? '').matchAll(IMAGE_TOKEN)].map(match => match[0]);
  return String(value ?? '').replace(/〔原图(\d+)〕/g, (label, number) => tokens[Number(number)-1] ?? label);
}

export function questionImageIds(value) {
  return [...new Set([...String(value ?? '').matchAll(IMAGE_TOKEN)].map(match => match[1]))];
}

export function hasCompleteMediaReferences(question) {
  const ids = questionImageIds([question.stem, question.explanation, ...(question.options || []).map(option => option.text)].join('\n'));
  return ids.length > 0 && ids.every(id => {
    const asset = question.media?.[id];
    return asset && ['image/png','image/jpeg'].includes(asset.mime) && typeof asset.data === 'string' && asset.data.length > 0;
  });
}

function dimensions(bytes, mime) {
  if (mime === 'image/png') {
    if (bytes.length < 33 || [137,80,78,71,13,10,26,10].some((byte,index) => bytes[index] !== byte) || String.fromCharCode(...bytes.slice(12,16)) !== 'IHDR') throw new Error('题图格式不完整');
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return [view.getUint32(16),view.getUint32(20)];
  }
  if (bytes.length < 4 || bytes[0] !== 255 || bytes[1] !== 216 || bytes.at(-2) !== 255 || bytes.at(-1) !== 217) throw new Error('题图格式不完整');
  let index = 2;
  while (index + 4 <= bytes.length) {
    if (bytes[index] !== 255) break;
    while (bytes[index] === 255) index++;
    const marker = bytes[index++];
    if (marker === 216 || marker === 217 || marker >= 208 && marker <= 215) continue;
    const size = bytes[index] * 256 + bytes[index+1];
    if (size < 2 || index + size > bytes.length) break;
    if ([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker)) {
      if (size < 8) break;
      return [bytes[index+5]*256+bytes[index+6],bytes[index+3]*256+bytes[index+4]];
    }
    index += size;
  }
  throw new Error('题图尺寸无法识别');
}

export function verifyQuestionMedia(id, asset) {
  const prior = checks.get(id);
  if (prior && prior.asset === asset) return prior.promise;
  const promise = (async () => {
    if (!/^[a-f0-9]{64}$/.test(id) || !asset || !['image/png','image/jpeg'].includes(asset.mime)) throw new Error('题图缺失，请刷新题库后重试');
    if (typeof asset.data !== 'string' || !asset.data.length || asset.data.length > Math.ceil(MAX_IMAGE_BYTES/3)*4 || asset.data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(asset.data)) throw new Error('题图数据不完整，请重新下载题库');
    let bytes;
    try { bytes = Uint8Array.from(atob(asset.data), letter => letter.charCodeAt(0)); }
    catch { throw new Error('题图数据不完整，请重新下载题库'); }
    if (bytes.length > MAX_IMAGE_BYTES) throw new Error('题图过大，请联系管理员');
    const [width,height] = dimensions(bytes,asset.mime);
    if (!Number.isInteger(asset.width) || !Number.isInteger(asset.height) || width !== asset.width || height !== asset.height || width < 1 || height < 1 || width > 4096 || height > 4096 || width * height > 10000000) throw new Error('题图尺寸校验失败，请重新下载题库');
    if (!globalThis.crypto?.subtle) throw new Error('浏览器无法校验题图，请使用新版浏览器');
    const digest = [...new Uint8Array(await globalThis.crypto.subtle.digest('SHA-256',bytes))].map(byte => byte.toString(16).padStart(2,'0')).join('');
    if (digest !== id) throw new Error('题图校验失败，请重新下载题库');
    return {src:`data:${asset.mime};base64,${asset.data}`,width,height};
  })();
  checks.set(id,{asset,promise});
  if (checks.size > 1000) checks.delete(checks.keys().next().value);
  return promise;
}
