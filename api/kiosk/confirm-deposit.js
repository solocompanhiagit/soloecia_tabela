const crypto = require('crypto');
const {
  getSupabaseAdmin,
  applyCors,
  validateKioskAuth
} = require('./_lib/supabaseAdmin');

module.exports = async function handler(req, res) {
  if (applyCors(req, res)) return;

  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Método não permitido. Utilize POST.' });
  }

  try {
    const supabase = getSupabaseAdmin();
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const kioskId = String(body.kiosk_id || req.headers['x-kiosk-id'] || 'TOTEM-GO-01').trim();

    const authCheck = await validateKioskAuth(req, supabase, kioskId);
    if (!authCheck.authorized) {
      return res.status(401).json({ error: authCheck.error });
    }

    const sessionToken = String(body.session_token || '').trim();
    const orderCodeInput = String(body.order_code || body.code || '').trim();
    const orderIdInput = String(body.order_id || '').trim();

    if (!sessionToken && !orderCodeInput && !orderIdInput) {
      return res.status(400).json({
        error: 'É necessário fornecer session_token ou order_code para confirmar o depósito.'
      });
    }

    // 1. Localiza a sessão em kiosk_deposit_sessions
    let sessionRecord = null;
    if (sessionToken) {
      const { data: sData } = await supabase
        .from('kiosk_deposit_sessions')
        .select('*')
        .eq('session_token', sessionToken)
        .maybeSingle();
      sessionRecord = sData;
    }

    // 2. Localiza o pedido correspondente
    const targetOrderId = (sessionRecord && sessionRecord.order_id) || orderIdInput || null;
    const targetOrderCode = (sessionRecord && sessionRecord.order_code) || orderCodeInput || null;

    let orderQuery = supabase.from('orders').select('*, samples(*), order_items(*)');
    if (targetOrderId) {
      orderQuery = orderQuery.eq('id', targetOrderId);
    } else {
      orderQuery = orderQuery.eq('code', targetOrderCode);
    }

    const { data: order, error: orderErr } = await orderQuery.maybeSingle();
    if (orderErr || !order) {
      return res.status(404).json({
        error: 'Pedido associado à sessão de depósito não encontrado.',
        details: orderErr ? orderErr.message : null
      });
    }

    const nowIso = new Date().toISOString();
    const relayTriggeredAt = body.relay_triggered_at || (sessionRecord && sessionRecord.relay_triggered_at) || nowIso;
    const doorOpenedAt = body.door_opened_at || (sessionRecord && sessionRecord.door_opened_at) || nowIso;
    const doorClosedAt = body.door_closed_at || nowIso;
    const urnCompartmentId = body.urn_compartment_id || order.urn_compartment_id || 'GAVETA-01';

    const receiptRandom = crypto.randomBytes(2).toString('hex').toUpperCase();
    const thermalReceiptCode =
      order.thermal_receipt_code ||
      `REC-${String(order.code).replace(/^SC-/, '')}-${receiptRandom}`;

    const samplesArray = Array.isArray(order.samples) ? order.samples : [];
    const expectedSamples = Math.max(1, Number(order.samples_count || samplesArray.length || 1));

    // 3. Atualiza a sessão em kiosk_deposit_sessions para completed
    if (sessionRecord) {
      await supabase
        .from('kiosk_deposit_sessions')
        .update({
          session_status: 'completed',
          relay_triggered_at: relayTriggeredAt,
          door_opened_at: doorOpenedAt,
          door_closed_at: doorClosedAt,
          completed_at: nowIso,
          thermal_receipt_code: thermalReceiptCode,
          telemetry_payload: {
            ...(sessionRecord.telemetry_payload || {}),
            door_sensor_verified: true,
            confirmed_by: body.confirmed_by || 'ESP8266_REED_SWITCH',
            rssi: body.rssi || -55
          }
        })
        .eq('id', sessionRecord.id);
    }

    // 4. Atualiza orders: status_entrega = 'depositado_em_urna', requires_kiosk_triage = true (com fallback pré-migração)
    const { error: updateOrderExtErr } = await supabase
      .from('orders')
      .update({
        status_entrega: 'depositado_em_urna',
        status: 'a_caminho',
        kiosk_id: kioskId,
        urn_compartment_id: urnCompartmentId,
        deposited_at: nowIso,
        requires_kiosk_triage: true,
        triage_samples_expected: expectedSamples,
        thermal_receipt_code: thermalReceiptCode,
        updated_at: nowIso
      })
      .eq('id', order.id);

    if (updateOrderExtErr) {
      await supabase
        .from('orders')
        .update({
          status: 'a_caminho',
          updated_at: nowIso
        })
        .eq('id', order.id);
    }

    // 5. Atualiza todas as amostras do pedido para sample_custody_status = 'depositada_urna'
    await supabase
      .from('samples')
      .update({
        sample_custody_status: 'depositada_urna',
        received_at_kiosk: nowIso
      })
      .eq('order_id', order.id);

    // 6. Incrementa current_bin_samples em kiosk_terminals
    const { data: terminal } = await supabase
      .from('kiosk_terminals')
      .select('id, current_bin_samples, bin_capacity_samples, status')
      .eq('id', kioskId)
      .maybeSingle();

    let updatedBinSamples = expectedSamples;
    let updatedTerminalStatus = 'online';

    if (terminal) {
      updatedBinSamples = Number(terminal.current_bin_samples || 0) + expectedSamples;
      const cap = Number(terminal.bin_capacity_samples || 60);
      updatedTerminalStatus = updatedBinSamples >= cap ? 'urna_cheia' : 'online';

      await supabase
        .from('kiosk_terminals')
        .update({
          current_bin_samples: updatedBinSamples,
          status: updatedTerminalStatus,
          last_heartbeat_at: nowIso,
          last_door_state: 'CLOSED',
          updated_at: nowIso
        })
        .eq('id', kioskId);
    }

    // 7. Registra auditoria em order_status_history
    await supabase.from('order_status_history').insert({
      order_id: order.id,
      from_status: 'a_caminho',
      to_status: 'a_caminho',
      status_entrega: 'depositado_em_urna',
      changed_by: `Urna ${kioskId} (Gaveta Fechada)`,
      actor_type: 'esp8266_hardware',
      kiosk_id: kioskId,
      metadata: {
        session_token: sessionToken || null,
        thermal_receipt_code: thermalReceiptCode,
        deposited_at: nowIso,
        samples_deposited: expectedSamples,
        urn_compartment_id: urnCompartmentId,
        relay_triggered_at: relayTriggeredAt,
        door_opened_at: doorOpenedAt,
        door_closed_at: doorClosedAt
      }
    });

    // 8. Monta objeto estruturado thermal_receipt para impressão de bobina 80mm
    const thermalReceipt = {
      receipt_code: thermalReceiptCode,
      order_id: order.id,
      order_code: order.code,
      custody_qr_hash: order.custody_qr_hash || `SC24H-${order.code.replace(/-/g, '')}`,
      kiosk_id: kioskId,
      urn_compartment_id: urnCompartmentId,
      unit_name: order.unit_name || 'Unidade Goiás',
      unit_phone: order.unit_phone || '556232614562',
      deposited_at: nowIso,
      timestamps: {
        relay_triggered_at: relayTriggeredAt,
        door_opened_at: doorOpenedAt,
        door_closed_at: doorClosedAt
      },
      titular: {
        nome: order.nome,
        cpf_cnpj: order.cpf_cnpj,
        fazenda: order.fazenda,
        cidade_uf: order.cidade_uf,
        telefone: order.telefone
      },
      portador: {
        is_titular: order.portador_is_titular !== false,
        nome: order.portador_nome || order.remetente || order.nome,
        documento: order.portador_documento || order.cpf_cnpj,
        telefone: order.portador_telefone || order.telefone,
        relacao: order.portador_relacao || 'Titular / Responsável'
      },
      samples_count: expectedSamples,
      samples_summary: samplesArray.map((s, idx) => ({
        seq: s.seq || idx + 1,
        sample_barcode: s.sample_barcode || `${order.code}-S${String(idx + 1).padStart(2, '0')}`,
        sample_label: s.sample_label || `Amostra ${idx + 1}`,
        material: s.material || 'solo',
        analysis: s.analysis || 'Análise Contratada',
        talhao: s.talhao || '-'
      })),
      financial: {
        subtotal: Number(order.subtotal || 0),
        discount_val: Number(order.discount_val || 0),
        total: Number(order.total || 0)
      },
      legal_statement:
        'Custódia física registrada sob monitoramento eletrônico 24h. A validação definitiva das amostras ocorrerá na triagem de bancada do laboratório.'
    };

    return res.status(200).json({
      success: true,
      message: 'Depósito em urna confirmado e custódia registrada com sucesso.',
      kiosk_bin_state: {
        kiosk_id: kioskId,
        current_bin_samples: updatedBinSamples,
        status: updatedTerminalStatus
      },
      thermal_receipt: thermalReceipt
    });
  } catch (err) {
    console.error('[confirm-deposit] Erro inesperado:', err);
    return res.status(500).json({
      error: 'Erro interno ao confirmar depósito na urna.',
      details: err.message
    });
  }
};
