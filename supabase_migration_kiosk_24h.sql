-- ============================================================================
-- LABORATÓRIO SOLO & COMPANHIA - MIGRAÇÃO SUBSISTEMA TOTEM 24H (KIOSK + URNA ESP8266)
-- Arquivo: supabase_migration_kiosk_24h.sql
-- Script SQL 100% Idempotente para PostgreSQL / Supabase
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. CRIAÇÃO DOS TIPOS ENUMERADOS (IDEMPOTENTE)
-- ----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'delivery_status_enum') then
    create type public.delivery_status_enum as enum (
      'pendente_entrega',
      'autorizado_totem',
      'depositado_em_urna',
      'retirado_da_urna',
      'em_triagem_laboratorio',
      'validado_laboratorio',
      'divergencia_triagem'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'origin_channel_enum') then
    create type public.origin_channel_enum as enum (
      'web_balcao',
      'web_totem_24h',
      'kiosk_walkin_24h'
    );
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 2. TABELA DE TERMINAIS FÍSICOS E URNAS COLETORAS (kiosk_terminals)
-- ----------------------------------------------------------------------------
create table if not exists public.kiosk_terminals (
  id text primary key,
  unit_id text not null default 'goias',
  name text not null,
  location_description text,
  esp8266_device_id text not null,
  esp8266_local_ip text default '192.168.1.50',
  api_secret_hash text not null,
  lock_relay_pin integer not null default 5,
  door_sensor_pin integer not null default 4,
  unlock_timeout_sec integer not null default 45,
  bin_capacity_samples integer not null default 60 check (bin_capacity_samples > 0),
  current_bin_samples integer not null default 0 check (current_bin_samples >= 0),
  status text not null default 'online' check (status in ('online', 'offline', 'manutencao', 'urna_cheia')),
  last_heartbeat_at timestamptz default now(),
  last_door_state text default 'CLOSED',
  last_rssi integer default -58,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Seeds iniciais dos terminais das Unidades Goiás e Bahia
insert into public.kiosk_terminals (
  id, unit_id, name, location_description, esp8266_device_id, esp8266_local_ip,
  api_secret_hash, lock_relay_pin, door_sensor_pin, unlock_timeout_sec,
  bin_capacity_samples, current_bin_samples, status, last_heartbeat_at
) values
  (
    'TOTEM-GO-01',
    'goias',
    'Totem Autoatendimento 24h • Unidade Goiás',
    'Recepção Externa 24h - Laboratório Solo & Cia (Goiás)',
    'ESP8266-URN-GO01',
    '192.168.1.180',
    encode(digest('SOLOECIA_KIOSK_GO_01_SECRET_2026', 'sha256'), 'hex'),
    5,
    4,
    45,
    60,
    0,
    'online',
    now()
  ),
  (
    'TOTEM-BA-01',
    'bahia',
    'Totem Autoatendimento 24h • Unidade Bahia',
    'Recepção Externa 24h - Laboratório Solo & Cia (Bahia)',
    'ESP8266-URN-BA01',
    '192.168.2.180',
    encode(digest('SOLOECIA_KIOSK_BA_01_SECRET_2026', 'sha256'), 'hex'),
    5,
    4,
    45,
    60,
    0,
    'online',
    now()
  )
on conflict (id) do update set
  unit_id = excluded.unit_id,
  name = excluded.name,
  location_description = excluded.location_description,
  esp8266_device_id = excluded.esp8266_device_id,
  lock_relay_pin = excluded.lock_relay_pin,
  door_sensor_pin = excluded.door_sensor_pin,
  unlock_timeout_sec = excluded.unlock_timeout_sec,
  bin_capacity_samples = excluded.bin_capacity_samples,
  updated_at = now();

-- ----------------------------------------------------------------------------
-- 3. EVOLUÇÃO DA TABELA public.orders (CUSTÓDIA, PORTADOR E TRIAGEM 24H)
-- ----------------------------------------------------------------------------
alter table public.orders
  add column if not exists status_entrega public.delivery_status_enum not null default 'pendente_entrega',
  add column if not exists origin_channel public.origin_channel_enum not null default 'web_balcao',
  add column if not exists custody_qr_hash text,
  add column if not exists kiosk_id text references public.kiosk_terminals(id) on delete set null,
  add column if not exists urn_compartment_id text default 'GAVETA-01',
  add column if not exists deposited_at timestamptz,
  add column if not exists thermal_receipt_code text,
  add column if not exists portador_is_titular boolean not null default true,
  add column if not exists portador_nome text,
  add column if not exists portador_documento text,
  add column if not exists portador_telefone text,
  add column if not exists portador_relacao text,
  add column if not exists requires_kiosk_triage boolean not null default false,
  add column if not exists triage_checked_by text,
  add column if not exists triage_checked_at timestamptz,
  add column if not exists triage_samples_expected integer,
  add column if not exists triage_samples_received integer,
  add column if not exists triage_packaging_ok boolean,
  add column if not exists triage_discrepancy_notes text;

create unique index if not exists idx_orders_custody_qr_hash on public.orders(custody_qr_hash) where custody_qr_hash is not null;
create index if not exists idx_orders_status_entrega on public.orders(status_entrega);
create index if not exists idx_orders_requires_kiosk_triage on public.orders(requires_kiosk_triage);
create index if not exists idx_orders_kiosk_id on public.orders(kiosk_id);

-- ----------------------------------------------------------------------------
-- 4. EVOLUÇÃO DA TABELA public.samples (RASTREABILIDADE POR SACO / AMOSTRA)
-- ----------------------------------------------------------------------------
alter table public.samples
  add column if not exists sample_barcode text,
  add column if not exists sample_custody_status text not null default 'aguardando'
    check (sample_custody_status in ('aguardando', 'depositada_urna', 'conferida_ok', 'avariada', 'ausente')),
  add column if not exists received_at_kiosk timestamptz,
  add column if not exists verified_in_lab_at timestamptz,
  add column if not exists lab_internal_protocol text,
  add column if not exists physical_condition_notes text;

create index if not exists idx_samples_barcode on public.samples(sample_barcode);
create index if not exists idx_samples_custody_status on public.samples(sample_custody_status);

-- ----------------------------------------------------------------------------
-- 5. TABELA DE SESSÕES DE DEPÓSITO E TELEMETRIA DA TRAVA (kiosk_deposit_sessions)
--    E EVOLUÇÃO DE public.order_status_history
-- ----------------------------------------------------------------------------
create table if not exists public.kiosk_deposit_sessions (
  id uuid primary key default gen_random_uuid(),
  session_token text not null unique,
  kiosk_id text not null references public.kiosk_terminals(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  order_code text not null,
  custody_qr_hash text,
  session_status text not null default 'authorized'
    check (session_status in ('authorized', 'unlocked', 'door_open', 'completed', 'expired', 'aborted')),
  hmac_signature text not null,
  pulse_ms integer not null default 3500,
  unlock_timeout_sec integer not null default 45,
  authorized_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '5 minutes'),
  relay_triggered_at timestamptz,
  door_opened_at timestamptz,
  door_closed_at timestamptz,
  completed_at timestamptz,
  thermal_receipt_code text,
  telemetry_payload jsonb not null default '{}'::jsonb
);

create index if not exists idx_kiosk_sessions_kiosk_status on public.kiosk_deposit_sessions(kiosk_id, session_status);
create index if not exists idx_kiosk_sessions_order_id on public.kiosk_deposit_sessions(order_id);

alter table public.order_status_history
  add column if not exists status_entrega public.delivery_status_enum,
  add column if not exists actor_type text default 'system',
  add column if not exists kiosk_id text,
  add column if not exists metadata jsonb default '{}'::jsonb;

-- ----------------------------------------------------------------------------
-- 6. TRIGGERS DE SINCRONIZAÇÃO DE STATUS LEGADO E GERAÇÃO DE CÓDIGOS DE CUSTÓDIA
-- ----------------------------------------------------------------------------
create or replace function public.fn_sync_order_legacy_status()
returns trigger
language plpgsql
as $$
begin
  -- Gera custody_qr_hash automaticamente se omitido no INSERT ou UPDATE
  if new.custody_qr_hash is null or btrim(new.custody_qr_hash) = '' then
    new.custody_qr_hash := 'SC24H-' || replace(coalesce(new.code, 'SC26'), '-', '') || '-' || upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6));
  end if;

  -- Se o titular é o próprio portador e portador_nome não foi preenchido, espelha os dados do titular
  if new.portador_is_titular is true then
    if new.portador_nome is null or btrim(new.portador_nome) = '' then
      new.portador_nome := coalesce(nullif(btrim(new.remetente), ''), new.nome);
    end if;
    if new.portador_documento is null or btrim(new.portador_documento) = '' then
      new.portador_documento := new.cpf_cnpj;
    end if;
    if new.portador_telefone is null or btrim(new.portador_telefone) = '' then
      new.portador_telefone := new.telefone;
    end if;
    if new.portador_relacao is null or btrim(new.portador_relacao) = '' then
      new.portador_relacao := 'Titular / Responsável';
    end if;
  end if;

  -- Sincronização bidirecional entre status_entrega (Totem 24h) e status legado (cadastrado, a_caminho, recebido)
  if tg_op = 'INSERT' or (new.status_entrega is distinct from old.status_entrega) then
    if new.status_entrega = 'pendente_entrega' then
      new.status := 'cadastrado';
    elsif new.status_entrega in ('autorizado_totem', 'depositado_em_urna', 'retirado_da_urna', 'em_triagem_laboratorio', 'divergencia_triagem') then
      new.status := 'a_caminho';
    elsif new.status_entrega = 'validado_laboratorio' then
      new.status := 'recebido';
    end if;
  elsif tg_op = 'UPDATE' and (new.status is distinct from old.status) and (new.status_entrega is not distinct from old.status_entrega) then
    if new.status = 'recebido' and new.status_entrega <> 'validado_laboratorio' then
      new.status_entrega := 'validado_laboratorio';
      new.requires_kiosk_triage := false;
    elsif new.status = 'cadastrado' then
      new.status_entrega := 'pendente_entrega';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_sync_order_legacy_status on public.orders;
create trigger trg_sync_order_legacy_status
  before insert or update on public.orders
  for each row
  execute function public.fn_sync_order_legacy_status();

-- Trigger para gerar sample_barcode automaticamente em public.samples se omitido
create or replace function public.fn_generate_sample_barcode()
returns trigger
language plpgsql
as $$
declare
  v_order_code text;
begin
  if new.sample_barcode is null or btrim(new.sample_barcode) = '' then
    select code into v_order_code from public.orders where id = new.order_id limit 1;
    v_order_code := coalesce(v_order_code, 'SC-2026');
    new.sample_barcode := v_order_code || '-S' || lpad(coalesce(new.seq, 1)::text, 2, '0');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_generate_sample_barcode on public.samples;
create trigger trg_generate_sample_barcode
  before insert or update on public.samples
  for each row
  execute function public.fn_generate_sample_barcode();

-- Backfill em registros já existentes no banco
update public.orders
set custody_qr_hash = 'SC24H-' || replace(code, '-', '') || '-' || upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6))
where custody_qr_hash is null or btrim(custody_qr_hash) = '';

update public.samples s
set sample_barcode = o.code || '-S' || lpad(coalesce(s.seq, 1)::text, 2, '0')
from public.orders o
where s.order_id = o.id
  and (s.sample_barcode is null or btrim(s.sample_barcode) = '');

-- ----------------------------------------------------------------------------
-- 7. ATUALIZAÇÃO DA FUNÇÃO RPC submit_order PARA RETORNAR custody_qr_hash E sample_barcode
-- ----------------------------------------------------------------------------
create or replace function public.submit_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_code text;
  v_custody_qr_hash text;
  v_origin_channel public.origin_channel_enum := 'web_balcao';
  v_seq bigint;
  v_subtotal numeric(12,2) := 0;
  v_total_qty integer := 0;
  v_samples_count integer := 0;
  v_effective_count integer := 0;
  v_coupon_code text := upper(btrim(coalesce(p_payload->>'coupon_code', '')));
  v_coupon_pct numeric(5,2) := 0;
  v_volume_pct numeric(5,2) := 0;
  v_discount_pct numeric(5,2) := 0;
  v_discount_val numeric(12,2) := 0;
  v_discount_reason text := '';
  v_total numeric(12,2) := 0;
  v_item jsonb;
  v_sample jsonb;
  v_pkg_price numeric(10,2);
  v_pkg_name text;
  v_qty integer;
  v_idx integer := 0;
  v_sample_barcode text;
  v_sample_barcodes jsonb := '[]'::jsonb;
  v_portador_is_titular boolean := coalesce((p_payload->>'portador_is_titular')::boolean, true);
begin
  -- Gera código único do pedido: SC-2026-00101
  v_seq := nextval('public.order_code_seq');
  v_code := 'SC-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

  v_custody_qr_hash := nullif(btrim(coalesce(p_payload->>'custody_qr_hash', '')), '');
  if v_custody_qr_hash is null then
    v_custody_qr_hash := 'SC24H-' || replace(v_code, '-', '') || '-' || upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 6));
  end if;

  if (p_payload->>'origin_channel') in ('web_balcao', 'web_totem_24h', 'kiosk_walkin_24h') then
    v_origin_channel := (p_payload->>'origin_channel')::public.origin_channel_enum;
  end if;

  -- Conta amostras enviadas
  if jsonb_typeof(p_payload->'samples') = 'array' then
    v_samples_count := jsonb_array_length(p_payload->'samples');
  end if;

  -- Calcula subtotal conferindo os preços no banco de dados
  if jsonb_typeof(p_payload->'items') = 'array' then
    for v_item in select * from jsonb_array_elements(p_payload->'items')
    loop
      v_qty := greatest(1, coalesce((v_item->>'qty')::integer, 1));
      select price, name into v_pkg_price, v_pkg_name
      from public.packages
      where id = (v_item->>'id') or lower(name) = lower(v_item->>'name')
      limit 1;

      if v_pkg_price is null then
        v_pkg_price := greatest(0, coalesce((v_item->>'price')::numeric, 0));
      end if;

      v_subtotal := v_subtotal + (v_pkg_price * v_qty);
      v_total_qty := v_total_qty + v_qty;
    end loop;
  end if;

  v_effective_count := greatest(v_total_qty, v_samples_count);

  -- Verifica cupom ativo
  if v_coupon_code <> '' then
    select percent into v_coupon_pct
    from public.coupons
    where upper(code) = v_coupon_code and active = true
    limit 1;
    v_coupon_pct := coalesce(v_coupon_pct, 0);
  end if;

  -- Regra de volume (> 15 amostras = 5%)
  if v_effective_count > 15 then
    v_volume_pct := 5.00;
  end if;

  -- Descontos NÃO cumulativos (prevalece o maior)
  if v_coupon_pct >= v_volume_pct and v_coupon_pct > 0 then
    v_discount_pct := v_coupon_pct;
    v_discount_reason := 'Cupom ' || v_coupon_code || ' (' || trim(to_char(v_coupon_pct, 'FM990.##')) || '%)';
  elsif v_volume_pct > 0 then
    v_discount_pct := v_volume_pct;
    v_discount_reason := 'Volume > 15 amostras (5%)';
  end if;

  v_discount_val := round(v_subtotal * (v_discount_pct / 100.0), 2);
  v_total := greatest(0, v_subtotal - v_discount_val);

  -- Insere o Pedido
  insert into public.orders (
    code, status, status_entrega, origin_channel, custody_qr_hash, kiosk_id,
    unit_id, unit_name, unit_phone,
    nome, cpf_cnpj, fazenda, endereco, cep, cidade_uf, telefone, email, remetente,
    portador_is_titular, portador_nome, portador_documento, portador_telefone, portador_relacao,
    coupon_code, samples_count, subtotal, discount_pct, discount_val, discount_reason, total
  ) values (
    v_code,
    'cadastrado',
    'pendente_entrega',
    v_origin_channel,
    v_custody_qr_hash,
    nullif(btrim(coalesce(p_payload->>'kiosk_id', '')), ''),
    coalesce(nullif(p_payload->>'unit_id', ''), 'goias'),
    coalesce(nullif(p_payload->>'unit_name', ''), 'Unidade Goiás'),
    coalesce(nullif(p_payload->>'unit_phone', ''), '556232614562'),
    coalesce(p_payload->>'nome', ''),
    coalesce(p_payload->>'cpf_cnpj', ''),
    coalesce(p_payload->>'fazenda', ''),
    coalesce(p_payload->>'endereco', ''),
    coalesce(p_payload->>'cep', ''),
    coalesce(p_payload->>'cidade_uf', ''),
    coalesce(p_payload->>'telefone', ''),
    coalesce(p_payload->>'email', ''),
    coalesce(p_payload->>'remetente', ''),
    v_portador_is_titular,
    coalesce(nullif(p_payload->>'portador_nome', ''), coalesce(p_payload->>'remetente', p_payload->>'nome', '')),
    coalesce(nullif(p_payload->>'portador_documento', ''), coalesce(p_payload->>'cpf_cnpj', '')),
    coalesce(nullif(p_payload->>'portador_telefone', ''), coalesce(p_payload->>'telefone', '')),
    coalesce(nullif(p_payload->>'portador_relacao', ''), 'Titular / Responsável'),
    nullif(v_coupon_code, ''),
    v_samples_count,
    v_subtotal,
    v_discount_pct,
    v_discount_val,
    v_discount_reason,
    v_total
  ) returning id into v_order_id;

  -- Insere os Itens do Orçamento
  if jsonb_typeof(p_payload->'items') = 'array' then
    for v_item in select * from jsonb_array_elements(p_payload->'items')
    loop
      v_qty := greatest(1, coalesce((v_item->>'qty')::integer, 1));
      select price, name into v_pkg_price, v_pkg_name
      from public.packages
      where id = (v_item->>'id') or lower(name) = lower(v_item->>'name')
      limit 1;

      if v_pkg_price is null then
        v_pkg_price := greatest(0, coalesce((v_item->>'price')::numeric, 0));
      end if;
      if v_pkg_name is null then
        v_pkg_name := coalesce(v_item->>'name', 'Análise');
      end if;

      insert into public.order_items (
        order_id, package_id, name_snapshot, unit_price_snapshot, qty, line_total
      ) values (
        v_order_id, v_item->>'id', v_pkg_name, v_pkg_price, v_qty, v_pkg_price * v_qty
      );
    end loop;
  end if;

  -- Insere as Amostras com sample_barcode individual
  if jsonb_typeof(p_payload->'samples') = 'array' then
    v_idx := 0;
    for v_sample in select * from jsonb_array_elements(p_payload->'samples')
    loop
      v_idx := v_idx + 1;
      v_sample_barcode := coalesce(nullif(btrim(v_sample->>'sample_barcode'), ''), v_code || '-S' || lpad(v_idx::text, 2, '0'));
      insert into public.samples (
        order_id, seq, material, analysis, sample_label,
        talhao, profundidade, cultura, dt_plantio, dt_coleta, hora_coleta, dae_estagio,
        sample_barcode, sample_custody_status
      ) values (
        v_order_id,
        v_idx,
        coalesce(v_sample->>'material', 'solo'),
        coalesce(v_sample->>'analysis', 'A definir'),
        coalesce(nullif(v_sample->>'sampleId', ''), coalesce(nullif(v_sample->>'sample_label', ''), 'Amostra ' || v_idx)),
        v_sample->>'talhao',
        v_sample->>'profundidade',
        v_sample->>'cultura',
        coalesce(v_sample->>'dtPlantio', v_sample->>'dt_plantio'),
        coalesce(v_sample->>'dtColeta', v_sample->>'dt_coleta'),
        coalesce(v_sample->>'horaColeta', v_sample->>'hora_coleta'),
        coalesce(v_sample->>'daeEstagio', v_sample->>'dae_estagio'),
        v_sample_barcode,
        'aguardando'
      );
      v_sample_barcodes := v_sample_barcodes || jsonb_build_array(jsonb_build_object(
        'seq', v_idx,
        'sample_barcode', v_sample_barcode,
        'sample_label', coalesce(nullif(v_sample->>'sampleId', ''), coalesce(nullif(v_sample->>'sample_label', ''), 'Amostra ' || v_idx)),
        'material', coalesce(v_sample->>'material', 'solo'),
        'analysis', coalesce(v_sample->>'analysis', 'A definir'),
        'talhao', coalesce(v_sample->>'talhao', ''),
        'profundidade', coalesce(v_sample->>'profundidade', ''),
        'cultura', coalesce(v_sample->>'cultura', '')
      ));
    end loop;
  end if;

  -- Registra histórico inicial de status
  insert into public.order_status_history (
    order_id, from_status, to_status, status_entrega, changed_by, actor_type, kiosk_id
  ) values (
    v_order_id, null, 'cadastrado', 'pendente_entrega',
    case when v_origin_channel = 'kiosk_walkin_24h' then 'Totem 24h (Walk-in)' else 'Cliente (Ficha Online)' end,
    case when v_origin_channel = 'kiosk_walkin_24h' then 'kiosk' else 'client_web' end,
    nullif(btrim(coalesce(p_payload->>'kiosk_id', '')), '')
  );

  return jsonb_build_object(
    'id', v_order_id,
    'code', v_code,
    'custody_qr_hash', v_custody_qr_hash,
    'origin_channel', v_origin_channel,
    'subtotal', v_subtotal,
    'discount_pct', v_discount_pct,
    'discount_val', v_discount_val,
    'discount_reason', v_discount_reason,
    'total', v_total,
    'samples_count', v_samples_count,
    'thermal_labels', v_sample_barcodes
  );
end;
$$;

grant execute on function public.submit_order(jsonb) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- 8. PERMISSÕES E POLÍTICAS RLS PARA KIOSK 24H E PAINEL ADMIN
-- ----------------------------------------------------------------------------
grant select on public.kiosk_terminals to anon, authenticated;
grant all privileges on table public.kiosk_terminals, public.kiosk_deposit_sessions to authenticated;

alter table public.kiosk_terminals enable row level security;
alter table public.kiosk_deposit_sessions enable row level security;

drop policy if exists "kiosk_terminals_select_public" on public.kiosk_terminals;
create policy "kiosk_terminals_select_public" on public.kiosk_terminals
  for select to anon, authenticated using (true);

drop policy if exists "kiosk_terminals_write_auth" on public.kiosk_terminals;
create policy "kiosk_terminals_write_auth" on public.kiosk_terminals
  for all to authenticated using (true) with check (true);

drop policy if exists "kiosk_sessions_auth_all" on public.kiosk_deposit_sessions;
create policy "kiosk_sessions_auth_all" on public.kiosk_deposit_sessions
  for all to authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- 9. HABILITAÇÃO DA PUBLICAÇÃO SUPABASE REALTIME (IDEMPOTENTE)
-- ----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders'
    ) then
      alter publication supabase_realtime add table public.orders;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'kiosk_terminals'
    ) then
      alter publication supabase_realtime add table public.kiosk_terminals;
    end if;

    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'kiosk_deposit_sessions'
    ) then
      alter publication supabase_realtime add table public.kiosk_deposit_sessions;
    end if;
  end if;
end $$;
