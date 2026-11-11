const {
  getSupabaseAdmin,
  applyCors
} = require('./_lib/supabaseAdmin');

module.exports = async function handler(req, res) {
  if (applyCors(req, res)) return;

  if (req.method !== 'PATCH' && req.method !== 'POST') {
    return res.status(405).json({ error: 'Método não permitido. Utilize PATCH ou POST.' });
  }

  try {
    const supabase = getSupabaseAdmin();
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});

    const action = String(body.action || 'approve').trim(); // 'collect_batch' | 'approve' | 'discrepancy' | 'empty_bin'
    const orderId = body.order_id || null;
    const orderCode = body.order_code || body.code || null;
    const checkedBy = String(body.triage_checked_by || body.checked_by || 'Analista de Triagem').trim();
    const nowIso = new Date().toISOString();

    // Ação especial: Esvaziar / Recolher todos os lotes de uma urna específica
    if (action === 'empty_bin' && body.kiosk_id) {
      const targetKiosk = String(body.kiosk_id).trim();
      await supabase
        .from('kiosk_terminals')
        .update({
          current_bin_samples: 0,
          status: 'online',
          updated_at: nowIso
        })
        .eq('id', targetKiosk);

      return res.status(200).json({
        success: true,
        action: 'empty_bin',
        kiosk_id: targetKiosk,
        current_bin_samples: 0,
        message: `Urna do terminal ${targetKiosk} esvaziada e liberada para novos depósitos.`
      });
    }

    if (!orderId && !orderCode) {
      return res.status(400).json({
        error: 'Informe order_id ou order_code para executar a conferência de triagem.'
      });
    }

    let query = supabase.from('orders').select('*, samples(*)');
    if (orderId) {
      query = query.eq('id', orderId);
    } else {
      query = query.eq('code', orderCode);
    }

    const { data: order, error: orderErr } = await query.maybeSingle();
    if (orderErr || !order) {
      return res.status(404).json({
        error: 'Pedido não encontrado para triagem.',
        details: orderErr ? orderErr.message : null
      });
    }

    const expectedSamples = Number(
      order.triage_samples_expected ||
      order.samples_count ||
      (Array.isArray(order.samples) ? order.samples.length : 0)
    );

    // (a) Recolhimento do lote da urna para a bancada de triagem
    if (action === 'collect_batch') {
      await supabase
        .from('orders')
        .update({
          status_entrega: 'em_triagem_laboratorio',
          status: 'a_caminho',
          requires_kiosk_triage: true,
          triage_checked_by: checkedBy,
          updated_at: nowIso
        })
        .eq('id', order.id);

      // Desconta as amostras recolhidas da ocupação física da urna no terminal
      if (order.kiosk_id) {
        const { data: term } = await supabase
          .from('kiosk_terminals')
          .select('current_bin_samples, status')
          .eq('id', order.kiosk_id)
          .maybeSingle();

        if (term) {
          const newCount = Math.max(0, Number(term.current_bin_samples || 0) - expectedSamples);
          await supabase
            .from('kiosk_terminals')
            .update({
              current_bin_samples: newCount,
              status: term.status === 'urna_cheia' ? 'online' : term.status,
              updated_at: nowIso
            })
            .eq('id', order.kiosk_id);
        }
      }

      await supabase.from('order_status_history').insert({
        order_id: order.id,
        from_status: order.status || 'a_caminho',
        to_status: 'a_caminho',
        status_entrega: 'em_triagem_laboratorio',
        changed_by: checkedBy,
        actor_type: 'lab_analyst',
        kiosk_id: order.kiosk_id,
        metadata: { action: 'collect_batch', collected_at: nowIso }
      });

      return res.status(200).json({
        success: true,
        action: 'collect_batch',
        order_id: order.id,
        order_code: order.code,
        status_entrega: 'em_triagem_laboratorio',
        status: 'a_caminho',
        message: `Lote ${order.code} recolhido da urna e iniciado em triagem de bancada.`
      });
    }

    // Atualiza cada amostra individualmente (protocolo interno de bancada e condição física)
    const sampleReviews = Array.isArray(body.samples_verification) ? body.samples_verification : [];
    const existingSamples = Array.isArray(order.samples) ? order.samples : [];

    let confirmedSamplesCount = 0;

    if (sampleReviews.length > 0) {
      for (const rev of sampleReviews) {
        const custodyStatus = rev.sample_custody_status || 'conferida_ok';
        if (custodyStatus === 'conferida_ok') confirmedSamplesCount++;

        const updateFields = {
          sample_custody_status: custodyStatus,
          verified_in_lab_at: nowIso,
          lab_internal_protocol: rev.lab_internal_protocol || null,
          physical_condition_notes: rev.physical_condition_notes || null
        };

        if (rev.id) {
          await supabase.from('samples').update(updateFields).eq('id', rev.id);
        } else if (rev.sample_barcode) {
          await supabase
            .from('samples')
            .update(updateFields)
            .eq('order_id', order.id)
            .eq('sample_barcode', rev.sample_barcode);
        } else if (rev.seq) {
          await supabase
            .from('samples')
            .update(updateFields)
            .eq('order_id', order.id)
            .eq('seq', rev.seq);
        }
      }
    } else if (action === 'approve') {
      // Se nenhuma lista individual foi enviada na aprovação, valida todas as amostras como conferida_ok
      confirmedSamplesCount = expectedSamples;
      for (let i = 0; i < existingSamples.length; i++) {
        const s = existingSamples[i];
        const autoProtocol =
          s.lab_internal_protocol ||
          `LAB-${new Date().getFullYear()}-${String(order.code).replace(/\D/g, '').slice(-4)}-${String(s.seq || i + 1).padStart(2, '0')}`;
        await supabase
          .from('samples')
          .update({
            sample_custody_status: 'conferida_ok',
            verified_in_lab_at: nowIso,
            lab_internal_protocol: autoProtocol
          })
          .eq('id', s.id);
      }
    }

    const receivedCount =
      body.triage_samples_received !== undefined
        ? Number(body.triage_samples_received)
        : (confirmedSamplesCount || expectedSamples);
    const packagingOk = body.triage_packaging_ok !== false;
    const discrepancyNotes = String(body.triage_discrepancy_notes || '').trim();

    // (b) Aprovação da conferência física no laboratório
    if (action === 'approve') {
      await supabase
        .from('orders')
        .update({
          status_entrega: 'validado_laboratorio',
          status: 'recebido',
          requires_kiosk_triage: false,
          triage_checked_by: checkedBy,
          triage_checked_at: nowIso,
          triage_samples_expected: expectedSamples,
          triage_samples_received: receivedCount,
          triage_packaging_ok: packagingOk,
          triage_discrepancy_notes: discrepancyNotes || null,
          updated_at: nowIso
        })
        .eq('id', order.id);

      await supabase.from('order_status_history').insert({
        order_id: order.id,
        from_status: order.status || 'a_caminho',
        to_status: 'recebido',
        status_entrega: 'validado_laboratorio',
        changed_by: checkedBy,
        actor_type: 'lab_analyst',
        kiosk_id: order.kiosk_id,
        metadata: {
          action: 'approve',
          triage_samples_expected: expectedSamples,
          triage_samples_received: receivedCount,
          triage_packaging_ok: packagingOk,
          triage_discrepancy_notes: discrepancyNotes
        }
      });

      return res.status(200).json({
        success: true,
        action: 'approve',
        order_id: order.id,
        order_code: order.code,
        status_entrega: 'validado_laboratorio',
        status: 'recebido',
        requires_kiosk_triage: false,
        triage_checked_by: checkedBy,
        triage_checked_at: nowIso,
        message: `Conferência física concluída! Pedido ${order.code} validado e recebido no laboratório.`
      });
    }

    // (c) Registro de divergência na triagem física
    await supabase
      .from('orders')
      .update({
        status_entrega: 'divergencia_triagem',
        status: 'a_caminho',
        requires_kiosk_triage: true,
        triage_checked_by: checkedBy,
        triage_checked_at: nowIso,
        triage_samples_expected: expectedSamples,
        triage_samples_received: receivedCount,
        triage_packaging_ok: packagingOk,
        triage_discrepancy_notes: discrepancyNotes || 'Divergência reportada na conferência física da urna.',
        updated_at: nowIso
      })
      .eq('id', order.id);

    await supabase.from('order_status_history').insert({
      order_id: order.id,
      from_status: order.status || 'a_caminho',
      to_status: 'a_caminho',
      status_entrega: 'divergencia_triagem',
      changed_by: checkedBy,
      actor_type: 'lab_analyst',
      kiosk_id: order.kiosk_id,
      metadata: {
        action: 'discrepancy',
        triage_samples_expected: expectedSamples,
        triage_samples_received: receivedCount,
        triage_packaging_ok: packagingOk,
        triage_discrepancy_notes: discrepancyNotes
      }
    });

    return res.status(200).json({
      success: true,
      action: 'discrepancy',
      order_id: order.id,
      order_code: order.code,
      status_entrega: 'divergencia_triagem',
      status: 'a_caminho',
      requires_kiosk_triage: true,
      triage_checked_by: checkedBy,
      triage_checked_at: nowIso,
      message: `Divergência registrada no pedido ${order.code}.`
    });
  } catch (err) {
    console.error('[triage-verify] Erro inesperado:', err);
    return res.status(500).json({
      error: 'Erro interno ao registrar conferência física de triagem.',
      details: err.message
    });
  }
};
