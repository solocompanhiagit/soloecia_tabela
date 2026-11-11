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
    const kioskId = body.kiosk_id || req.headers['x-kiosk-id'] || 'TOTEM-GO-01';

    const authCheck = await validateKioskAuth(req, supabase, kioskId);
    if (!authCheck.authorized) {
      return res.status(401).json({ error: authCheck.error });
    }

    const nome = String(body.nome || '').trim();
    const cpf_cnpj = String(body.cpf_cnpj || '').trim();
    const fazenda = String(body.fazenda || '').trim();
    const cidade_uf = String(body.cidade_uf || '').trim();
    const telefone = String(body.telefone || '').trim();
    const email = String(body.email || '').trim();
    const endereco = String(body.endereco || '').trim();
    const cep = String(body.cep || '').trim();

    const portador_is_titular = body.portador_is_titular !== false;
    const portador_nome = portador_is_titular
      ? (String(body.portador_nome || body.remetente || nome).trim())
      : String(body.portador_nome || '').trim();
    const portador_documento = portador_is_titular
      ? (String(body.portador_documento || cpf_cnpj).trim())
      : String(body.portador_documento || '').trim();
    const portador_telefone = portador_is_titular
      ? (String(body.portador_telefone || telefone).trim())
      : String(body.portador_telefone || '').trim();
    const portador_relacao = portador_is_titular
      ? 'Titular / Produtor'
      : String(body.portador_relacao || 'Portador / Entregador').trim();

    if (!nome || !cpf_cnpj || !fazenda || !cidade_uf || !telefone) {
      return res.status(400).json({
        error: 'Campos obrigatórios de faturamento ausentes (nome, cpf_cnpj, fazenda, cidade_uf, telefone).'
      });
    }

    if (!portador_is_titular && (!portador_nome || !portador_documento)) {
      return res.status(400).json({
        error: 'Quando o entregador não é o titular, informe Nome e CPF/RG do portador.'
      });
    }

    const itemsInput = Array.isArray(body.items) ? body.items : [];
    const samplesInput = Array.isArray(body.samples) ? body.samples : [];

    if (itemsInput.length === 0 && samplesInput.length === 0) {
      return res.status(400).json({
        error: 'O pedido no Totem deve conter pelo menos 1 análise/pacote e 1 amostra identificada.'
      });
    }

    // 1. Consulta catálogo oficial em public.packages para cálculo fidedigno no servidor
    const { data: catalogRows } = await supabase
      .from('packages')
      .select('id, name, price, category, active');

    const catalogMapById = new Map();
    const catalogMapByName = new Map();
    if (Array.isArray(catalogRows)) {
      catalogRows.forEach(pkg => {
        catalogMapById.set(String(pkg.id).toLowerCase(), pkg);
        catalogMapByName.set(String(pkg.name).toLowerCase(), pkg);
      });
    }

    let subtotal = 0;
    let totalItemsQty = 0;
    const normalizedItems = [];

    for (const rawItem of itemsInput) {
      const qty = Math.max(1, parseInt(rawItem.qty, 10) || 1);
      const itemIdKey = String(rawItem.id || rawItem.package_id || '').toLowerCase();
      const itemNameKey = String(rawItem.name || '').toLowerCase();
      const dbPkg = catalogMapById.get(itemIdKey) || catalogMapByName.get(itemNameKey);

      const unitPrice = dbPkg ? Number(dbPkg.price) : Math.max(0, Number(rawItem.price || 0));
      const pkgName = dbPkg ? dbPkg.name : (rawItem.name || 'Análise Agronômica');
      const pkgId = dbPkg ? dbPkg.id : (rawItem.id || 'custom');
      const lineTotal = Number((unitPrice * qty).toFixed(2));

      subtotal += lineTotal;
      totalItemsQty += qty;

      normalizedItems.push({
        id: pkgId,
        package_id: pkgId,
        name: pkgName,
        name_snapshot: pkgName,
        price: unitPrice,
        unit_price_snapshot: unitPrice,
        qty,
        line_total: lineTotal
      });
    }

    subtotal = Number(subtotal.toFixed(2));
    const samplesCount = samplesInput.length;
    const effectiveCount = Math.max(totalItemsQty, samplesCount);

    // 2. Validação de cupom no banco (public.coupons) + regra de volume (>15 amostras = 5%)
    const couponCode = String(body.coupon_code || '').trim().toUpperCase();
    let couponPct = 0;
    if (couponCode) {
      const { data: couponRow } = await supabase
        .from('coupons')
        .select('code, percent, active')
        .ilike('code', couponCode)
        .eq('active', true)
        .maybeSingle();

      if (couponRow && Number(couponRow.percent) > 0) {
        couponPct = Number(couponRow.percent);
      } else {
        // Fallback para RPC validate_coupon caso RLS restrinja leitura direta com chave anon
        const { data: rpcCoupon } = await supabase.rpc('validate_coupon', { p_code: couponCode });
        if (rpcCoupon && rpcCoupon.valid) {
          couponPct = Number(rpcCoupon.percent || 0);
        }
      }
    }

    const volumePct = effectiveCount > 15 ? 5.0 : 0;
    let discountPct = 0;
    let discountReason = '';

    if (couponPct >= volumePct && couponPct > 0) {
      discountPct = couponPct;
      discountReason = `Cupom ${couponCode} (${couponPct}%)`;
    } else if (volumePct > 0) {
      discountPct = volumePct;
      discountReason = 'Volume > 15 amostras (5%)';
    }

    const discountVal = Number((subtotal * (discountPct / 100)).toFixed(2));
    const total = Number(Math.max(0, subtotal - discountVal).toFixed(2));

    const unit_id = body.unit_id || (kioskId.includes('BA') ? 'bahia' : 'goias');
    const unit_name = body.unit_name || (unit_id === 'bahia' ? 'Unidade Bahia' : 'Unidade Goiás');
    const unit_phone = body.unit_phone || (unit_id === 'bahia' ? '5577998604562' : '556232614562');

    // 3. Tenta inserir diretamente via Service Role; se RLS bloquear (ex: chave anon), usa submit_order RPC
    const randSuffix = crypto.randomBytes(3).toString('hex').toUpperCase();
    const generatedCode = `SC-${new Date().getFullYear()}-${String(Math.floor(10000 + Math.random() * 90000))}`;
    const generatedQrHash = `SC24H-${generatedCode.replace(/-/g, '')}-${randSuffix}`;

    const rpcPayload = {
      unit_id,
      unit_name,
      unit_phone,
      kiosk_id: kioskId,
      origin_channel: 'kiosk_walkin_24h',
      custody_qr_hash: generatedQrHash,
      nome,
      cpf_cnpj,
      fazenda,
      endereco,
      cep,
      cidade_uf,
      telefone,
      email,
      remetente: portador_nome || nome,
      portador_is_titular,
      portador_nome,
      portador_documento,
      portador_telefone,
      portador_relacao,
      coupon_code: couponCode,
      items: normalizedItems,
      samples: samplesInput.map((s, idx) => ({
        material: s.material || 'solo',
        analysis: s.analysis || (normalizedItems[0] ? normalizedItems[0].name : 'Solo Completa'),
        sampleId: s.sample_label || s.sampleId || `Amostra ${idx + 1}`,
        talhao: s.talhao || `Talhão ${idx + 1}`,
        profundidade: s.profundidade || '0-20 cm',
        cultura: s.cultura || '',
        dtPlantio: s.dt_plantio || s.dtPlantio || '',
        dtColeta: s.dt_coleta || s.dtColeta || new Date().toISOString().slice(0, 10),
        horaColeta: s.hora_coleta || s.horaColeta || new Date().toTimeString().slice(0, 5),
        daeEstagio: s.dae_estagio || s.daeEstagio || ''
      }))
    };

    let orderId = null;
    let finalOrderCode = generatedCode;
    let finalCustodyQrHash = generatedQrHash;

    // Chamada prioritária via RPC submit_order (usa sequence oficial order_code_seq no banco)
    const { data: rpcOrderData, error: rpcOrderErr } = await supabase.rpc('submit_order', {
      p_payload: rpcPayload
    });

    if (!rpcOrderErr && rpcOrderData && rpcOrderData.code) {
      orderId = rpcOrderData.id;
      finalOrderCode = rpcOrderData.code;
      finalCustodyQrHash =
        rpcOrderData.custody_qr_hash ||
        `SC24H-${finalOrderCode.replace(/-/g, '')}-${randSuffix}`;

      // Garante atualização dos campos estendidos caso submit_order no banco ainda seja a versão anterior à migração
      await supabase
        .from('orders')
        .update({
          origin_channel: 'kiosk_walkin_24h',
          status_entrega: 'pendente_entrega',
          custody_qr_hash: finalCustodyQrHash,
          kiosk_id: kioskId,
          portador_is_titular,
          portador_nome,
          portador_documento,
          portador_telefone,
          portador_relacao
        })
        .eq('id', orderId);
    } else {
      // Fallback de inserção direta nas tabelas orders, order_items e samples
      const { data: insertedOrder, error: insertErr } = await supabase
        .from('orders')
        .insert({
          code: finalOrderCode,
          status: 'cadastrado',
          status_entrega: 'pendente_entrega',
          origin_channel: 'kiosk_walkin_24h',
          custody_qr_hash: finalCustodyQrHash,
          kiosk_id: kioskId,
          unit_id,
          unit_name,
          unit_phone,
          nome,
          cpf_cnpj,
          fazenda,
          endereco,
          cep,
          cidade_uf,
          telefone,
          email,
          remetente: portador_nome || nome,
          portador_is_titular,
          portador_nome,
          portador_documento,
          portador_telefone,
          portador_relacao,
          coupon_code: couponCode || null,
          samples_count: samplesCount,
          subtotal,
          discount_pct: discountPct,
          discount_val: discountVal,
          discount_reason: discountReason,
          total
        })
        .select('id, code, custody_qr_hash')
        .single();

      if (insertErr) {
        return res.status(500).json({
          error: 'Falha ao gravar pedido Walk-in no banco de dados.',
          details: insertErr.message
        });
      }

      orderId = insertedOrder.id;
      finalOrderCode = insertedOrder.code;
      finalCustodyQrHash = insertedOrder.custody_qr_hash || finalCustodyQrHash;

      if (normalizedItems.length > 0) {
        await supabase.from('order_items').insert(
          normalizedItems.map(it => ({
            order_id: orderId,
            package_id: it.package_id,
            name_snapshot: it.name_snapshot,
            unit_price_snapshot: it.unit_price_snapshot,
            qty: it.qty,
            line_total: it.line_total
          }))
        );
      }

      if (samplesInput.length > 0) {
        await supabase.from('samples').insert(
          samplesInput.map((s, idx) => ({
            order_id: orderId,
            seq: idx + 1,
            material: s.material || 'solo',
            analysis: s.analysis || 'Solo Completa',
            sample_label: s.sample_label || s.sampleId || `Amostra ${idx + 1}`,
            talhao: s.talhao || `Talhão ${idx + 1}`,
            profundidade: s.profundidade || '0-20 cm',
            cultura: s.cultura || '',
            dt_plantio: s.dt_plantio || s.dtPlantio || '',
            dt_coleta: s.dt_coleta || s.dtColeta || new Date().toISOString().slice(0, 10),
            hora_coleta: s.hora_coleta || s.horaColeta || '',
            dae_estagio: s.dae_estagio || s.daeEstagio || '',
            sample_barcode: `${finalOrderCode}-S${String(idx + 1).padStart(2, '0')}`,
            sample_custody_status: 'aguardando'
          }))
        );
      }
    }

    // 4. Monta o array thermal_labels formatado para impressão imediata em bobina térmica 80mm/58mm
    const thermalLabels = samplesInput.map((s, idx) => {
      const seqNum = idx + 1;
      const seqStr = String(seqNum).padStart(2, '0');
      const sampleBarcode = `${finalOrderCode}-S${seqStr}`;
      const sampleLabel = s.sample_label || s.sampleId || `Amostra ${seqStr}`;
      const mat = String(s.material || 'solo').toUpperCase();
      const analysis = s.analysis || (normalizedItems[0] ? normalizedItems[0].name : 'Solo Completa');

      return {
        seq: seqNum,
        total_samples: samplesCount,
        order_code: finalOrderCode,
        sample_barcode: sampleBarcode,
        qr_payload: `SC|${sampleBarcode}|ORD:${finalOrderCode}|ID:${sampleLabel}|MAT:${mat}|ANA:${analysis}`,
        sample_label: sampleLabel,
        material: mat,
        analysis,
        talhao: s.talhao || '-',
        profundidade: s.profundidade || '-',
        cultura: s.cultura || '-',
        produtor: nome,
        fazenda,
        cidade_uf,
        unit_name,
        printed_at: new Date().toISOString()
      };
    });

    return res.status(201).json({
      success: true,
      order_id: orderId,
      code: finalOrderCode,
      custody_qr_hash: finalCustodyQrHash,
      origin_channel: 'kiosk_walkin_24h',
      status_entrega: 'pendente_entrega',
      kiosk_id: kioskId,
      unit_id,
      unit_name,
      financial: {
        subtotal,
        discount_pct: discountPct,
        discount_val: discountVal,
        discount_reason: discountReason,
        total
      },
      portador: {
        portador_is_titular,
        portador_nome,
        portador_documento,
        portador_telefone,
        portador_relacao
      },
      samples_count: samplesCount,
      thermal_labels: thermalLabels
    });
  } catch (err) {
    console.error('[walkin-order] Erro inesperado:', err);
    return res.status(500).json({
      error: 'Erro interno ao processar cadastro Walk-in 24h no Totem.',
      details: err.message
    });
  }
};
