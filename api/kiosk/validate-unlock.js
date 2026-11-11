const crypto = require('crypto');
const {
  getSupabaseAdmin,
  generateHmacSignature,
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

    const rawScan = String(body.custody_qr_hash || body.code || body.qr_input || '').trim();
    if (!rawScan) {
      return res.status(400).json({
        error: 'Informe o código do pedido (SC-2026-...) ou aproxime o QR Code da Ficha de Remessa.'
      });
    }

    // Extrai código ou custody_qr_hash caso o QR Code contenha pipes (ex: SC|SC-2026-00105-S01|...)
    let normalizedCode = rawScan.toUpperCase();
    let normalizedHash = rawScan.toUpperCase();

    if (rawScan.includes('|')) {
      const parts = rawScan.split('|');
      for (const p of parts) {
        const clean = p.trim();
        if (clean.startsWith('SC24H-')) normalizedHash = clean;
        if (clean.startsWith('ORD:')) normalizedCode = clean.replace('ORD:', '').trim();
        if (/^SC-\d{4}-\d+/i.test(clean)) {
          normalizedCode = clean.replace(/-S\d+$/i, '').replace(/-\d{2}$/, '');
        }
      }
    } else if (/^SC-\d{4}-\d+-(S?\d{2})$/i.test(normalizedCode)) {
      // Caso o cliente tenha bipado a etiqueta de uma amostra individual (ex: SC-2026-00101-S01)
      normalizedCode = normalizedCode.replace(/-(S?\d{2})$/i, '');
    }

    // 1. Verifica status e lotação da urna coletora do Totem (kiosk_terminals)
    const { data: terminal } = await supabase
      .from('kiosk_terminals')
      .select('*')
      .eq('id', kioskId)
      .maybeSingle();

    const binCapacity = terminal ? Number(terminal.bin_capacity_samples || 60) : 60;
    const currentBin = terminal ? Number(terminal.current_bin_samples || 0) : 0;

    if (terminal && (terminal.status === 'urna_cheia' || currentBin >= binCapacity)) {
      return res.status(507).json({
        error: 'A urna coletora deste terminal atingiu a capacidade máxima de amostras. Por favor, aguarde a coleta ou dirija-se à recepção.',
        code: 'URN_FULL',
        kiosk_id: kioskId,
        current_bin_samples: currentBin,
        bin_capacity_samples: binCapacity
      });
    }

    if (terminal && terminal.status === 'manutencao') {
      return res.status(503).json({
        error: 'Este terminal encontra-se temporariamente em manutenção preventiva.',
        code: 'KIOSK_MAINTENANCE'
      });
    }

    // 2. Busca o pedido por custody_qr_hash ou por code (com fallback pré-migração)
    let order = null;
    const { data: orderByHash, error: hashQueryErr } = await supabase
      .from('orders')
      .select('*, samples(*), order_items(*)')
      .or(`custody_qr_hash.eq.${normalizedHash},code.eq.${normalizedCode}`)
      .limit(1)
      .maybeSingle();

    if (!hashQueryErr && orderByHash) {
      order = orderByHash;
    } else {
      const { data: orderByCode } = await supabase
        .from('orders')
        .select('*, samples(*), order_items(*)')
        .eq('code', normalizedCode)
        .limit(1)
        .maybeSingle();
      order = orderByCode;
    }

    if (!order) {
      // Tentativa flexível caso o usuário tenha digitado apenas os números finais (ex: 00101)
      const digitsOnly = normalizedCode.replace(/\D/g, '');
      if (digitsOnly.length >= 3) {
        const { data: flexOrder } = await supabase
          .from('orders')
          .select('*, samples(*), order_items(*)')
          .ilike('code', `%${digitsOnly}`)
          .limit(1)
          .maybeSingle();
        order = flexOrder;
      }
    }

    if (!order) {
      return res.status(404).json({
        error: `Pedido não localizado para o código "${rawScan}". Verifique o código SC-2026-... na Ficha de Remessa ou faça um Novo Cadastro no Totem.`,
        code: 'ORDER_NOT_FOUND'
      });
    }

    // 3. Proteção Anti-Replay: Verifica se o pedido já foi depositado ou validado
    const currentDeliveryStatus = order.status_entrega || 'pendente_entrega';
    const replayBlockedStatuses = [
      'depositado_em_urna',
      'retirado_da_urna',
      'em_triagem_laboratorio',
      'validado_laboratorio',
      'divergencia_triagem'
    ];

    if (replayBlockedStatuses.includes(currentDeliveryStatus) || order.status === 'recebido') {
      return res.status(409).json({
        error: `Este QR Code / Pedido (${order.code}) já teve suas amostras depositadas anteriormente (${currentDeliveryStatus}). Cada pedido permite apenas um único depósito em urna.`,
        code: 'QR_ALREADY_DEPOSITED',
        order_code: order.code,
        status_entrega: currentDeliveryStatus,
        deposited_at: order.deposited_at
      });
    }

    const expectedSamples = Math.max(
      1,
      Number(order.samples_count || (Array.isArray(order.samples) ? order.samples.length : 1))
    );

    if (currentBin + expectedSamples > binCapacity) {
      return res.status(507).json({
        error: `Capacidade insuficiente na urna para ${expectedSamples} amostra(s) (Ocupação atual: ${currentBin}/${binCapacity}).`,
        code: 'URN_CAPACITY_EXCEEDED',
        current_bin_samples: currentBin,
        bin_capacity_samples: binCapacity,
        order_samples: expectedSamples
      });
    }

    // Se o cliente apenas consultou os dados do pedido para exibir o resumo antes de confirmar o portador
    if (body.lookup_only === true) {
      return res.status(200).json({
        success: true,
        lookup_only: true,
        order: {
          id: order.id,
          code: order.code,
          custody_qr_hash: order.custody_qr_hash || `SC24H-${order.code.replace(/-/g, '')}`,
          status: order.status,
          status_entrega: currentDeliveryStatus,
          nome: order.nome,
          cpf_cnpj: order.cpf_cnpj,
          fazenda: order.fazenda,
          cidade_uf: order.cidade_uf,
          telefone: order.telefone,
          remetente: order.remetente,
          unit_id: order.unit_id,
          unit_name: order.unit_name,
          samples_count: expectedSamples,
          total: order.total,
          samples: order.samples || [],
          order_items: order.order_items || []
        }
      });
    }

    // 4. Dados do Portador (Titular vs Terceiro/Portador)
    const portador_is_titular = body.portador_is_titular !== false;
    const portador_nome = portador_is_titular
      ? (body.portador_nome || order.remetente || order.nome)
      : String(body.portador_nome || '').trim();
    const portador_documento = portador_is_titular
      ? (body.portador_documento || order.cpf_cnpj)
      : String(body.portador_documento || '').trim();
    const portador_telefone = portador_is_titular
      ? (body.portador_telefone || order.telefone)
      : String(body.portador_telefone || '').trim();
    const portador_relacao = portador_is_titular
      ? 'Titular / Responsável Técnico'
      : String(body.portador_relacao || 'Portador / Entregador').trim();

    if (!portador_is_titular && (!portador_nome || !portador_documento)) {
      return res.status(400).json({
        error: 'Informe o Nome Completo e o CPF/RG do portador responsável pela entrega física.',
        code: 'PORTADOR_REQUIRED'
      });
    }

    const custodyHash =
      order.custody_qr_hash ||
      `SC24H-${String(order.code).replace(/-/g, '')}-${crypto.randomBytes(2).toString('hex').toUpperCase()}`;

    // 5. Gera Token de Sessão e Assinatura HMAC-SHA256 para a trava eletromecânica ESP8266
    const sessionToken = `KSESS-${Date.now()}-${crypto.randomBytes(6).toString('hex').toUpperCase()}`;
    const pulseMs = 3500;
    const unlockTimeoutSec = terminal ? Number(terminal.unlock_timeout_sec || 45) : 45;
    const issuedAt = new Date().toISOString();
    const expiresAt = new Date(Date.now() + 5 * 60 * 1000).toISOString();

    const hmacPayload = `${kioskId}|${order.code}|${sessionToken}|${pulseMs}|${unlockTimeoutSec}`;
    const hmacSignature = generateHmacSignature(hmacPayload);

    // 6. Atualiza pedido com dados do portador e status_entrega = 'autorizado_totem' (com fallback pré-migração)
    const { error: updateExtErr } = await supabase
      .from('orders')
      .update({
        status_entrega: 'autorizado_totem',
        status: 'a_caminho',
        kiosk_id: kioskId,
        custody_qr_hash: custodyHash,
        portador_is_titular,
        portador_nome,
        portador_documento,
        portador_telefone,
        portador_relacao,
        updated_at: issuedAt
      })
      .eq('id', order.id);

    if (updateExtErr) {
      await supabase
        .from('orders')
        .update({
          status: 'a_caminho',
          remetente: portador_nome || order.remetente || order.nome,
          updated_at: issuedAt
        })
        .eq('id', order.id);
    }

    // 7. Registra sessão autorizada em kiosk_deposit_sessions
    await supabase.from('kiosk_deposit_sessions').insert({
      session_token: sessionToken,
      kiosk_id: kioskId,
      order_id: order.id,
      order_code: order.code,
      custody_qr_hash: custodyHash,
      session_status: 'authorized',
      hmac_signature: hmacSignature,
      pulse_ms: pulseMs,
      unlock_timeout_sec: unlockTimeoutSec,
      authorized_at: issuedAt,
      expires_at: expiresAt,
      telemetry_payload: {
        portador_is_titular,
        portador_nome,
        portador_documento,
        expected_samples: expectedSamples
      }
    });

    // 8. Registra histórico de auditoria
    await supabase.from('order_status_history').insert({
      order_id: order.id,
      from_status: order.status || 'cadastrado',
      to_status: 'a_caminho',
      status_entrega: 'autorizado_totem',
      changed_by: `Totem ${kioskId} (${portador_nome})`,
      actor_type: 'kiosk',
      kiosk_id: kioskId,
      metadata: {
        session_token: sessionToken,
        portador_is_titular,
        portador_nome,
        portador_documento,
        portador_relacao
      }
    });

    const hardwareCommand = {
      kiosk_id: kioskId,
      esp8266_device_id: terminal ? terminal.esp8266_device_id : 'ESP8266-URN-GO01',
      esp8266_local_ip: terminal ? terminal.esp8266_local_ip : '192.168.1.180',
      endpoint: `http://${terminal ? terminal.esp8266_local_ip || '192.168.1.180' : '192.168.1.180'}/unlock`,
      action: 'UNLOCK_URN',
      session_token: sessionToken,
      order_id: order.id,
      order_code: order.code,
      custody_qr_hash: custodyHash,
      relay_pin: terminal ? Number(terminal.lock_relay_pin || 5) : 5,
      door_sensor_pin: terminal ? Number(terminal.door_sensor_pin || 4) : 4,
      pulse_ms: pulseMs,
      unlock_timeout_sec: unlockTimeoutSec,
      hmac_payload: hmacPayload,
      hmac_signature: hmacSignature,
      issued_at: issuedAt,
      expires_at: expiresAt
    };

    return res.status(200).json({
      success: true,
      message: 'Custódia validada com sucesso. Trava eletromecânica autorizada.',
      order: {
        id: order.id,
        code: order.code,
        custody_qr_hash: custodyHash,
        nome: order.nome,
        cpf_cnpj: order.cpf_cnpj,
        fazenda: order.fazenda,
        cidade_uf: order.cidade_uf,
        unit_name: order.unit_name,
        samples_count: expectedSamples,
        total: order.total,
        portador_is_titular,
        portador_nome,
        portador_documento,
        portador_telefone,
        portador_relacao
      },
      hardware_command: hardwareCommand
    });
  } catch (err) {
    console.error('[validate-unlock] Erro inesperado:', err);
    return res.status(500).json({
      error: 'Erro interno ao validar destravamento da urna.',
      details: err.message
    });
  }
};
