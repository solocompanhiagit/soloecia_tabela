const {
  getSupabaseAdmin,
  applyCors,
  validateKioskAuth
} = require('./_lib/supabaseAdmin');

module.exports = async function handler(req, res) {
  if (applyCors(req, res)) return;

  if (req.method !== 'POST' && req.method !== 'GET') {
    return res.status(405).json({ error: 'Método não permitido. Utilize GET ou POST.' });
  }

  try {
    const supabase = getSupabaseAdmin();
    const body =
      req.method === 'POST'
        ? (typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {}))
        : {};

    const kioskId = String(
      body.kiosk_id ||
      (req.query && req.query.kiosk_id) ||
      req.headers['x-kiosk-id'] ||
      'TOTEM-GO-01'
    ).trim();

    const authCheck = await validateKioskAuth(req, supabase, kioskId);
    if (!authCheck.authorized) {
      return res.status(401).json({ error: authCheck.error });
    }

    const nowIso = new Date().toISOString();
    const doorState = String(body.door_state || (req.query && req.query.door_state) || 'CLOSED').toUpperCase();
    const rssi = Number(body.rssi || (req.query && req.query.rssi) || -56);
    const sessionToken = body.session_token || (req.query && req.query.session_token) || null;
    const eventType = body.event || (req.query && req.query.event) || null; // 'RELAY_TRIGGERED' | 'DOOR_OPENED' | 'DOOR_CLOSED'

    // 1. Se for POST com telemetria do ESP8266 ou do Totem, atualiza kiosk_terminals
    if (req.method === 'POST') {
      const updateTerminal = {
        last_heartbeat_at: nowIso,
        last_door_state: doorState,
        last_rssi: rssi,
        updated_at: nowIso
      };
      if (body.esp8266_local_ip) {
        updateTerminal.esp8266_local_ip = String(body.esp8266_local_ip).trim();
      }

      await supabase
        .from('kiosk_terminals')
        .update(updateTerminal)
        .eq('id', kioskId);

      // Se informou transição de estado de uma sessão ativa (ex: porta aberta)
      if (sessionToken && eventType) {
        const sessionUpdates = {};
        if (eventType === 'RELAY_TRIGGERED') {
          sessionUpdates.session_status = 'unlocked';
          sessionUpdates.relay_triggered_at = nowIso;
        } else if (eventType === 'DOOR_OPENED' || doorState === 'OPEN') {
          sessionUpdates.session_status = 'door_open';
          sessionUpdates.door_opened_at = nowIso;
        }

        if (Object.keys(sessionUpdates).length > 0) {
          await supabase
            .from('kiosk_deposit_sessions')
            .update(sessionUpdates)
            .eq('session_token', sessionToken);
        }
      }
    }

    // 2. Consulta estado do terminal e sessões de destravamento pendentes (session_status = 'authorized')
    const { data: terminal } = await supabase
      .from('kiosk_terminals')
      .select('*')
      .eq('id', kioskId)
      .maybeSingle();

    let sessionFilter = supabase
      .from('kiosk_deposit_sessions')
      .select('*')
      .eq('kiosk_id', kioskId)
      .order('authorized_at', { ascending: false })
      .limit(1);

    if (sessionToken) {
      sessionFilter = supabase
        .from('kiosk_deposit_sessions')
        .select('*')
        .eq('session_token', sessionToken)
        .maybeSingle();
    } else {
      sessionFilter = sessionFilter.in('session_status', ['authorized', 'unlocked', 'door_open']).maybeSingle();
    }

    const { data: activeSession } = await sessionFilter;

    let pendingUnlockCommand = null;
    if (activeSession && activeSession.session_status === 'authorized') {
      pendingUnlockCommand = {
        should_unlock: true,
        session_token: activeSession.session_token,
        order_id: activeSession.order_id,
        order_code: activeSession.order_code,
        custody_qr_hash: activeSession.custody_qr_hash,
        pulse_ms: activeSession.pulse_ms || 3500,
        unlock_timeout_sec: activeSession.unlock_timeout_sec || 45,
        hmac_signature: activeSession.hmac_signature,
        authorized_at: activeSession.authorized_at
      };
    }

    return res.status(200).json({
      success: true,
      server_time: nowIso,
      kiosk_id: kioskId,
      terminal: terminal || {
        id: kioskId,
        status: 'online',
        current_bin_samples: 0,
        bin_capacity_samples: 60,
        last_door_state: doorState,
        last_heartbeat_at: nowIso
      },
      active_session: activeSession || null,
      pending_command: pendingUnlockCommand
    });
  } catch (err) {
    console.error('[hardware-heartbeat] Erro inesperado:', err);
    return res.status(500).json({
      error: 'Erro interno no heartbeat do hardware ESP8266.',
      details: err.message
    });
  }
};
