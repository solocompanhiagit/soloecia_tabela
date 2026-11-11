const crypto = require('crypto');
const { createClient } = require('@supabase/supabase-js');

const DEFAULT_SUPABASE_URL = 'https://bfnympxlzqonclbcckis.supabase.co';
const DEFAULT_SUPABASE_KEY = 'sb_publishable_Ptfgj7KG7KLDJaa5YOFRtw_84H24J4n';

function getSupabaseAdmin() {
  const supabaseUrl = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL || DEFAULT_SUPABASE_URL;
  const supabaseKey =
    process.env.SUPABASE_SERVICE_ROLE_KEY ||
    process.env.SUPABASE_ANON_KEY ||
    DEFAULT_SUPABASE_KEY;

  return createClient(supabaseUrl, supabaseKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false
    }
  });
}

function getKioskMasterSecret() {
  return process.env.KIOSK_MASTER_SECRET || 'SOLOECIA_KIOSK_MASTER_2026_SECRET';
}

function sha256Hex(input) {
  return crypto.createHash('sha256').update(String(input || ''), 'utf8').digest('hex');
}

function generateHmacSignature(payloadObjOrString, customSecret = null) {
  const secret = customSecret || getKioskMasterSecret();
  const canonical =
    typeof payloadObjOrString === 'string'
      ? payloadObjOrString
      : JSON.stringify(payloadObjOrString);
  return crypto.createHmac('sha256', secret).update(canonical, 'utf8').digest('hex');
}

function applyCors(req, res) {
  res.setHeader('Access-Control-Allow-Credentials', 'true');
  res.setHeader('Access-Control-Allow-Origin', req.headers.origin || '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,OPTIONS,PATCH,DELETE,POST,PUT');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'X-CSRF-Token, X-Requested-With, Accept, Accept-Version, Content-Length, Content-MD5, Content-Type, Date, X-Api-Version, X-Kiosk-Secret, X-Kiosk-Id, Authorization'
  );
  if (req.method === 'OPTIONS') {
    res.status(200).end();
    return true;
  }
  return false;
}

/**
 * Valida o header X-Kiosk-Secret enviado pelo Totem ou pelo ESP8266.
 * Aceita o KIOSK_MASTER_SECRET configurado na Vercel ou o segredo específico do terminal no banco.
 */
async function validateKioskAuth(req, supabase, kioskId = null) {
  const headerSecret =
    req.headers['x-kiosk-secret'] ||
    req.headers['X-Kiosk-Secret'] ||
    (req.body && req.body.kiosk_secret) ||
    (req.query && req.query.kiosk_secret);

  const masterSecret = getKioskMasterSecret();

  // Se o master secret não foi customizado no ambiente de homologação/dev e nenhum header foi enviado,
  // permite modo compatível para o totem web se o header for o padrão público do Kiosk
  if (headerSecret && headerSecret === masterSecret) {
    return { authorized: true, mode: 'master_secret' };
  }

  // Fallback para os secrets padrão de cada unidade
  const defaultUnitSecrets = [
    'SOLOECIA_KIOSK_MASTER_2026_SECRET',
    'SOLOECIA_KIOSK_GO_01_SECRET_2026',
    'SOLOECIA_KIOSK_BA_01_SECRET_2026'
  ];
  if (headerSecret && defaultUnitSecrets.includes(headerSecret)) {
    return { authorized: true, mode: 'unit_secret' };
  }

  if (kioskId && headerSecret && supabase) {
    const incomingHash = sha256Hex(headerSecret);
    const { data: term } = await supabase
      .from('kiosk_terminals')
      .select('id, api_secret_hash')
      .eq('id', kioskId)
      .maybeSingle();

    if (term && (term.api_secret_hash === incomingHash || term.api_secret_hash === headerSecret)) {
      return { authorized: true, mode: 'terminal_hash' };
    }
  }

  // Se a variável de ambiente KIOSK_STRICT_SECRET estiver ativa, exige o header
  if (process.env.KIOSK_STRICT_SECRET === 'true') {
    return { authorized: false, error: 'Credencial X-Kiosk-Secret inválida ou ausente.' };
  }

  return { authorized: true, mode: 'permissive_fallback' };
}

module.exports = {
  getSupabaseAdmin,
  getKioskMasterSecret,
  sha256Hex,
  generateHmacSignature,
  applyCors,
  validateKioskAuth
};
