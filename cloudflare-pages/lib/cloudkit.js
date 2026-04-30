// Shared CloudKit Web Services client for the recipe-share preview
// flow. Used by both /r/[id] (HTML page with OG tags) and /img/[id]
// (image proxy) — they hit the same RecipeShare record and pull
// `recipeTitle` + `photo0` out of it.
//
// Auth model: server-to-server keys (ECDSA P-256). The Worker holds
// the private key as a Cloudflare env var (encrypted secret), signs
// each outbound request, and Apple verifies the signature against
// the public key registered in CloudKit Console.
//
// Lives outside the `functions/` directory so it isn't auto-routed —
// Pages Functions only routes files inside `functions/`. The bundler
// follows the relative `import` from each route handler and pulls
// this module into the deployment automatically.

/**
 * Look up a single record from the public database by record name.
 * Returns the record JSON (or null on 404). Throws on auth / network
 * errors so callers can fall through to the generic preview.
 *
 * @param {string} recordName - The `RecipeShare` record ID.
 * @param {object} env - Cloudflare Pages env bindings.
 *   - CLOUDKIT_CONTAINER_ID: e.g. "iCloud.com.llamascookbook.app"
 *   - CLOUDKIT_KEY_ID: short alphanumeric from CloudKit Console
 *   - CLOUDKIT_PRIVATE_KEY: PEM (PKCS#8 or SEC1)
 *   - CLOUDKIT_ENVIRONMENT: "production" or "development" (default production)
 */
export async function fetchShareRecord(recordName, env) {
  const containerID = env.CLOUDKIT_CONTAINER_ID;
  const keyID = env.CLOUDKIT_KEY_ID;
  const privateKeyPEM = env.CLOUDKIT_PRIVATE_KEY;
  const environment = env.CLOUDKIT_ENVIRONMENT || 'production';

  if (!containerID || !keyID || !privateKeyPEM) {
    throw new Error('CloudKit env vars missing (CLOUDKIT_CONTAINER_ID / CLOUDKIT_KEY_ID / CLOUDKIT_PRIVATE_KEY)');
  }

  const path = `/database/1/${containerID}/${environment}/public/records/lookup`;
  const url = `https://api.apple-cloudkit.com${path}`;
  const body = JSON.stringify({ records: [{ recordName }] });

  const { date, signature } = await signRequest({ privateKeyPEM, path, body });

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Apple-CloudKit-Request-KeyID': keyID,
      'X-Apple-CloudKit-Request-ISO8601Date': date,
      'X-Apple-CloudKit-Request-SignatureV1': signature,
    },
    body,
  });

  if (response.status === 404) return null;
  if (!response.ok) {
    const text = await response.text().catch(() => '');
    throw new Error(`CloudKit fetch failed: ${response.status} ${text.slice(0, 200)}`);
  }

  const data = await response.json();
  const record = data.records?.[0];
  if (!record || record.serverErrorCode) return null;
  return record;
}

/**
 * Convenience: extract the recipe title and the first gallery
 * photo's CKAsset URL from a fetched record. Both nullable —
 * recipes without a title still render with "A Recipe", and
 * recipes without photos fall back to the llama icon.
 */
export function extractPreviewFields(record) {
  if (!record) return { title: null, photoURL: null };
  const title = record.fields?.recipeTitle?.value || null;
  const photoAsset = record.fields?.photo0?.value;
  const photoURL = photoAsset?.downloadURL || null;
  return { title, photoURL };
}

// ---------- ECDSA signing ----------
//
// CloudKit Web Services request signature spec:
//   1. ISO 8601 date with 'Z' suffix, no fractional seconds.
//   2. SHA-256(body), base64-encoded.
//   3. String-to-sign = `${date}:${bodyHashB64}:${path}`.
//   4. Sign with ECDSA-SHA256 over P-256.
//   5. Convert raw R||S signature to DER, base64-encode.
//
// Web Crypto returns raw R||S; CloudKit requires DER. The
// conversion is ~30 lines below.

async function signRequest({ privateKeyPEM, path, body }) {
  const date = isoDateWithoutMillis();
  const bodyHash = await sha256Base64(body);
  const stringToSign = `${date}:${bodyHash}:${path}`;

  const key = await importECPrivateKey(privateKeyPEM);
  const rawSig = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(stringToSign)
  );
  const derSig = rawSignatureToDER(new Uint8Array(rawSig));
  const signature = bytesToBase64(derSig);

  return { date, signature };
}

function isoDateWithoutMillis() {
  // Apple wants `2026-04-29T12:34:56Z`, not `2026-04-29T12:34:56.789Z`.
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

async function sha256Base64(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return bytesToBase64(new Uint8Array(digest));
}

async function importECPrivateKey(pem) {
  const der = pemToBytes(pem);

  // CloudKit Console typically issues PKCS#8 (`-----BEGIN PRIVATE KEY-----`),
  // but some workflows export SEC1 (`-----BEGIN EC PRIVATE KEY-----`).
  // Try PKCS#8 first; if it fails, wrap the SEC1 key in a PKCS#8
  // envelope and retry.
  try {
    return await crypto.subtle.importKey(
      'pkcs8',
      der,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign']
    );
  } catch (_) {
    const pkcs8 = wrapSEC1AsPKCS8(der);
    return await crypto.subtle.importKey(
      'pkcs8',
      pkcs8,
      { name: 'ECDSA', namedCurve: 'P-256' },
      false,
      ['sign']
    );
  }
}

function pemToBytes(pem) {
  // Strip PEM headers/footers/whitespace, base64-decode the body.
  const b64 = pem
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('-----'))
    .join('');
  return base64ToBytes(b64);
}

// SEC1 → PKCS#8 envelope for P-256. PKCS#8 outer SEQUENCE wrapping
// an INTEGER 0 (version), an AlgorithmIdentifier (ecPublicKey OID +
// prime256v1 OID), and an OCTET STRING containing the SEC1 bytes.
function wrapSEC1AsPKCS8(sec1) {
  const algorithmIdent = [
    0x30, 0x13, // SEQUENCE, 19 bytes
    0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, // OID 1.2.840.10045.2.1 (ecPublicKey)
    0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, // OID 1.2.840.10045.3.1.7 (prime256v1)
  ];
  const octetString = [0x04, ...derLength(sec1.length), ...sec1];
  const inner = [0x02, 0x01, 0x00, ...algorithmIdent, ...octetString];
  return new Uint8Array([0x30, ...derLength(inner.length), ...inner]);
}

// Raw R||S (64 bytes for P-256) → DER ECDSA signature.
function rawSignatureToDER(raw) {
  if (raw.length !== 64) {
    throw new Error(`Expected 64-byte raw P-256 signature, got ${raw.length}`);
  }
  const r = encodeDERInteger(raw.slice(0, 32));
  const s = encodeDERInteger(raw.slice(32, 64));
  const total = r.length + s.length;
  return new Uint8Array([0x30, ...derLength(total), ...r, ...s]);
}

function encodeDERInteger(bytes) {
  // Trim leading zeros.
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  let trimmed = bytes.slice(i);
  // If the high bit is set, prepend 0x00 so the integer is treated
  // as positive (DER signed-int convention).
  if ((trimmed[0] & 0x80) !== 0) {
    const prefixed = new Uint8Array(trimmed.length + 1);
    prefixed.set(trimmed, 1);
    trimmed = prefixed;
  }
  return [0x02, ...derLength(trimmed.length), ...trimmed];
}

function derLength(n) {
  if (n < 0x80) return [n];
  if (n < 0x100) return [0x81, n];
  return [0x82, (n >> 8) & 0xff, n & 0xff];
}

function bytesToBase64(bytes) {
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function base64ToBytes(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}
