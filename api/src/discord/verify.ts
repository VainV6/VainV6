export async function verifyDiscordSignature(
  request: Request,
  publicKey: string,
  body: string,
): Promise<boolean> {
  const signature = request.headers.get('x-signature-ed25519');
  const timestamp  = request.headers.get('x-signature-timestamp');
  if (!signature || !timestamp) return false;

  const key = await crypto.subtle.importKey(
    'raw',
    hexToBytes(publicKey),
    { name: 'NODE-ED25519', namedCurve: 'NODE-ED25519' },
    false,
    ['verify'],
  );

  const data = new TextEncoder().encode(timestamp + body);
  const sig  = hexToBytes(signature);
  return crypto.subtle.verify('NODE-ED25519', key, sig, data);
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}
