-- ============================================================================
-- LABORATÓRIO SOLO & COMPANHIA - ESTRUTURA DE BANCO DE DADOS (SUPABASE 2026)
-- Execute este script no Supabase: SQL Editor -> New Query -> Run
-- ============================================================================

create extension if not exists pgcrypto;

-- 1. TABELA DE PACOTES, CARDS E DETERMINAÇÕES ISOLADAS (CATÁLOGO)
create table if not exists public.packages (
  id text primary key,
  category text not null check (category in ('solo', 'foliar', 'fertilizantes', 'bioas')),
  kind text not null default 'package' check (kind in ('package', 'extra')),
  name text not null,
  price numeric(10,2) not null check (price >= 0),
  badge text,
  badge_color text default 'emerald',
  description text,
  macronutrientes text,
  micronutrientes text,
  granulometria text,
  finalidades text[] default '{}'::text[],
  guide_when text,
  guide_detail text,
  highlight boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 100,
  updated_at timestamptz not null default now()
);

-- 2. TABELA DE CUPONS DE DESCONTO
create table if not exists public.coupons (
  code text primary key,
  percent numeric(5,2) not null check (percent > 0 and percent <= 100),
  description text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 3. SEQUÊNCIA E TABELA DE PEDIDOS / FICHAS DE REMESSA
create sequence if not exists public.order_code_seq start with 101;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  status text not null default 'cadastrado' check (status in ('cadastrado', 'a_caminho', 'recebido')),
  unit_id text not null default 'goias',
  unit_name text not null default 'Unidade Goiás',
  unit_phone text not null default '556232614562',
  nome text not null,
  cpf_cnpj text not null,
  fazenda text not null,
  endereco text,
  cep text,
  cidade_uf text not null,
  telefone text not null,
  email text,
  remetente text not null,
  coupon_code text,
  samples_count integer not null default 0,
  subtotal numeric(12,2) not null default 0,
  discount_pct numeric(5,2) not null default 0,
  discount_val numeric(12,2) not null default 0,
  discount_reason text,
  total numeric(12,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 4. ITENS DO ORÇAMENTO VINCULADOS AO PEDIDO
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  package_id text,
  name_snapshot text not null,
  unit_price_snapshot numeric(10,2) not null,
  qty integer not null check (qty > 0),
  line_total numeric(12,2) not null
);

-- 5. AMOSTRAS CADASTRADAS NA FICHA DE ENVIO
create table if not exists public.samples (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  seq integer not null,
  material text not null,
  analysis text,
  sample_label text not null,
  talhao text,
  profundidade text,
  cultura text,
  dt_plantio text,
  dt_coleta text,
  hora_coleta text,
  dae_estagio text,
  created_at timestamptz not null default now()
);

-- 6. HISTÓRICO DE MUDANÇA DE STATUS DO PEDIDO
create table if not exists public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  from_status text,
  to_status text not null,
  changed_by text,
  changed_at timestamptz not null default now()
);

create index if not exists idx_orders_created_at on public.orders(created_at desc);
create index if not exists idx_orders_status on public.orders(status);
create index if not exists idx_order_items_order_id on public.order_items(order_id);
create index if not exists idx_samples_order_id on public.samples(order_id);

-- ============================================================================
-- SEGURANÇA (ROW LEVEL SECURITY - RLS)
-- ============================================================================
alter table public.packages enable row level security;
alter table public.coupons enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.samples enable row level security;
alter table public.order_status_history enable row level security;

-- Catálogo: leitura pública (anon e authenticated); escrita apenas para equipe logada (authenticated)
drop policy if exists "packages_select_public" on public.packages;
create policy "packages_select_public" on public.packages
  for select to anon, authenticated using (true);

drop policy if exists "packages_write_auth" on public.packages;
create policy "packages_write_auth" on public.packages
  for all to authenticated using (true) with check (true);

-- Cupons: gerenciamento apenas para equipe autenticada
drop policy if exists "coupons_auth_all" on public.coupons;
create policy "coupons_auth_all" on public.coupons
  for all to authenticated using (true) with check (true);

-- Pedidos, Itens, Amostras e Histórico: leitura e edição no painel para equipe autenticada
drop policy if exists "orders_auth_all" on public.orders;
create policy "orders_auth_all" on public.orders
  for all to authenticated using (true) with check (true);

drop policy if exists "order_items_auth_all" on public.order_items;
create policy "order_items_auth_all" on public.order_items
  for all to authenticated using (true) with check (true);

drop policy if exists "samples_auth_all" on public.samples;
create policy "samples_auth_all" on public.samples
  for all to authenticated using (true) with check (true);

drop policy if exists "order_status_history_auth_all" on public.order_status_history;
create policy "order_status_history_auth_all" on public.order_status_history
  for all to authenticated using (true) with check (true);

-- ============================================================================
-- FUNÇÕES RPC SEGURAS (SECURITY DEFINER) PARA O FRONTEND PÚBLICO
-- ============================================================================

-- 1) Validação de Cupom no Servidor (oculta os cupons do código-fonte público)
create or replace function public.validate_coupon(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
begin
  if p_code is null or btrim(p_code) = '' then
    return jsonb_build_object('valid', false, 'percent', 0, 'code', '');
  end if;

  select code, percent into v_coupon
  from public.coupons
  where upper(code) = upper(btrim(p_code))
    and active = true
  limit 1;

  if not found then
    return jsonb_build_object('valid', false, 'percent', 0, 'code', upper(btrim(p_code)));
  end if;

  return jsonb_build_object('valid', true, 'percent', v_coupon.percent, 'code', v_coupon.code);
end;
$$;

grant execute on function public.validate_coupon(text) to anon, authenticated;

-- 2) Submissão Completa de Pedido e Amostras pelo Cliente
create or replace function public.submit_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_code text;
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
begin
  -- Gera código único do pedido: SC-2026-000101
  v_seq := nextval('public.order_code_seq');
  v_code := 'SC-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

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
    code, status, unit_id, unit_name, unit_phone,
    nome, cpf_cnpj, fazenda, endereco, cep, cidade_uf, telefone, email, remetente,
    coupon_code, samples_count, subtotal, discount_pct, discount_val, discount_reason, total
  ) values (
    v_code,
    'cadastrado',
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

  -- Insere as Amostras
  if jsonb_typeof(p_payload->'samples') = 'array' then
    v_idx := 0;
    for v_sample in select * from jsonb_array_elements(p_payload->'samples')
    loop
      v_idx := v_idx + 1;
      insert into public.samples (
        order_id, seq, material, analysis, sample_label,
        talhao, profundidade, cultura, dt_plantio, dt_coleta, hora_coleta, dae_estagio
      ) values (
        v_order_id,
        v_idx,
        coalesce(v_sample->>'material', 'solo'),
        coalesce(v_sample->>'analysis', 'A definir'),
        coalesce(nullif(v_sample->>'sampleId', ''), 'Amostra ' || v_idx),
        v_sample->>'talhao',
        v_sample->>'profundidade',
        v_sample->>'cultura',
        v_sample->>'dtPlantio',
        v_sample->>'dtColeta',
        v_sample->>'horaColeta',
        v_sample->>'daeEstagio'
      );
    end loop;
  end if;

  -- Registra histórico inicial de status
  insert into public.order_status_history (order_id, from_status, to_status, changed_by)
  values (v_order_id, null, 'cadastrado', 'Cliente (Ficha Online)');

  return jsonb_build_object(
    'id', v_order_id,
    'code', v_code,
    'subtotal', v_subtotal,
    'discount_pct', v_discount_pct,
    'discount_val', v_discount_val,
    'discount_reason', v_discount_reason,
    'total', v_total
  );
end;
$$;

grant execute on function public.submit_order(jsonb) to anon, authenticated;

-- ============================================================================
-- CARGA INICIAL DE DADOS (SEED): CUPOM E CATÁLOGO 2026 COMPLETO
-- ============================================================================

insert into public.coupons (code, percent, description, active)
values ('SENAR', 10.00, 'Desconto parceria SENAR (10%)', true)
on conflict (code) do update set
  percent = excluded.percent,
  active = excluded.active;

insert into public.packages (
  id, category, kind, name, price, badge, badge_color, description,
  macronutrientes, micronutrientes, granulometria, finalidades,
  guide_when, guide_detail, highlight, active, sort_order
) values
  ('solo-basica', 'solo', 'package', 'Solo Básica', 70.00, 'Mais Procurado', 'emerald', 'Indicada para monitoramento de rotina em pastagens, reformas de pasto e checagem de calagem. Avalia pH, P Mehlich, K, Ca, Mg, Al, H+Al, CTC, Saturação por Bases (V%) e granulometria (Física, Textura) completa.', 'pH CaCl2, Fósforo (Mehlich), Potássio, Cálcio, Magnésio, Alumínio, Acidez Total, CTC, Índices de Saturação, Matéria Orgânica, Carbono Orgânico, Relação de Bases, % Nutrientes na CTC.', NULL, 'Física Completa: Teor de Argila, Silte e Areia.', ARRAY['Correção de Acidez', 'Financiamento Agrícola', 'Pastagem e Reforma']::text[], 'Indicada para monitoramento de rotina em pastagens, reformas de pasto e checagem de necessidade de calcário.', 'Avalia a acidez ativa (pH CaCl2), Fósforo Mehlich, Potássio, Cálcio, Magnésio, Alumínio, Acidez Potencial (H+Al), CTC, Saturação por Bases (V%) e granulometria (Física, Textura) completa (Argila, Silte e Areia).', false, true, 10),
  ('solo-basica-enxofre', 'solo', 'package', 'Básica + Enxofre', 95.00, 'Enxofre Incluso', 'cyan', 'Ideal para monitoramento de fertilidade com necessidade de avaliar Enxofre (S). Muito recomendada para planejar a gessagem e para culturas perenes ou pastagens de alta lotação.', 'pH CaCl2, P, K, Ca, Mg, Al, CTC, Saturações, Matéria Orgânica + Enxofre (S).', NULL, 'Teor de Argila, Silte e Areia.', ARRAY['Pastagens', 'Culturas Perenes', 'Aplicação de Gesso']::text[], '', '', false, true, 20),
  ('solo-completa', 'solo', 'package', 'Solo Completa', 120.00, 'Recomendado', 'emerald', 'O pacote padrão e mais vendido para lavouras comerciais de grãos (soja, milho, algodão). Além da fertilidade química e física básica, adiciona todos os micronutrientes essenciais (B, Cu, Fe, Mn, Zn) e Enxofre.', 'pH CaCl2, Fósforo (Mehlich), Potássio, Cálcio, Magnésio, Alumínio, Enxofre, Acidez Total, CTC, Índices de Saturação, Matéria Orgânica, Carbono Orgânico, Relação de Bases, % Nutrientes na CTC.', 'Boro, Cobre, Ferro, Manganês e Zinco.', 'Granulometria (Física, Textura) completa (Argila, Silte e Areia).', ARRAY['Adubação de Alta Produtividade', 'Correção de Acidez', 'Correção Fosfatada', 'Financiamento']::text[], 'O padrão ouro para lavouras de soja, milho, algodão, feijão e café.', 'Reúne toda a fertilidade química e granulometria (Física, Textura) da Básica somadas ao Enxofre e a todos os micronutrientes essenciais (Boro, Cobre, Ferro, Manganês e Zinco). Indispensável para o planejamento do adubo de plantio e cobertura.', true, true, 30),
  ('solo-max', 'solo', 'package', 'Solo Max', 155.00, 'Alta Tecnologia', 'gold', 'Recomendada para áreas sob cultivo intensivo com histórico de adubação fosfatada ou solos com alta capacidade de fixação de fósforo. Inclui Fósforo Remanescente (P-Rem) ou Fósforo em Resina.', 'pH CaCl2, Fósforo (Mehlich), Potássio, Cálcio, Magnésio, Alumínio, Enxofre, Acidez Total, CTC, Índices de Saturação, Mat. Orgânica, Carbono Orgânico, Relação de Bases, P resina ou Remanescente.', 'Boro, Cobre, Ferro, Manganês e Zinco.', 'Granulometria (Física, Textura) (Argila, Silte e Areia).', ARRAY['Lavoura de Grãos', 'Correção Fosfatada Avançada', 'Financiamento', 'Manejo Fino']::text[], 'Recomendada para áreas de cultivo intensivo com histórico de alta adubação fosfatada ou solos muito argilosos com grande fixação de P.', 'Adiciona a quantificação de Fósforo Remanescente (P-Rem) ou Fósforo em Resina trocadora de íons, permitindo calibrar o tampão fosfatado e evitar desperdício de adubo.', false, true, 40),
  ('solo-max-plus', 'solo', 'package', 'Solo Max Plus', 180.00, 'Nível Máximo', 'gold', 'O diagnóstico mais avançado e aprofundado da fertilidade do solo. Avalia pH em CaCl2 e H2O, P Mehlich, P Resina, P-Rem, Níveis Críticos de P, S e Zn, e todos os macro e micronutrientes para agricultura de alta produtividade.', 'pH CaCl2, pH H2O, P (Mehlich), P Remanescente, Níveis Críticos de P, S, Zn, P em Resina, K, Na, Ca, Mg, Al, H+Al, S, CTC, Índices de Saturação, Matéria Orgânica, Relação de Bases, % CTC.', 'Boro, Cobre, Ferro, Manganês e Zinco.', 'Argila, Silte e Areia.', ARRAY['Adubação de Precisão', 'Gessagem & Calagem', 'Áreas de Alta Rentabilidade', 'Demais Culturas']::text[], 'A escolha máxima para agricultura de precisão, áreas sob plantio direto consolidado e busca por recordes de produtividade.', 'O mais detalhado raio-X da fertilidade: analisa níveis críticos de P, S e Zinco, pH em CaCl2 e água, P Mehlich, P Resina, P-Rem, saturação de bases e textura completa.', true, true, 50),
  ('solo-basica-sem-textura', 'solo', 'package', 'Básica s/ Textura + Enxofre', 85.00, 'Econômico', 'slate', 'Econômica para amostragens em profundidade (20-40 cm ou 40-60 cm) onde a textura (argila/silte/areia) já é conhecida. Focada no balanço de bases, saturação por alumínio e Enxofre para recomendação de gesso.', 'Macronutrientes + Enxofre (sem física).', NULL, 'Sem determinação física (indicado p/ áreas com histórico).', ARRAY['Profundidades de 20-40 cm', 'Pastagens', 'Culturas Perenes', 'Manejo com Gesso']::text[], 'Ideal para amostragens em profundidade (20-40 cm) onde a textura já é conhecida da safra anterior.', 'Focada no balanço de cátions, neutralização de alumínio tóxico em profundidade e determinação de Enxofre (S) para cálculo exato da necessidade de gessagem.', false, true, 60),
  ('solo-basica-pres', 'solo', 'package', 'Solo Básica + Pres', 100.00, 'P-Remanescente', 'cyan', 'Recomendada para áreas sob plantio direto consolidado que adotam o método de resina trocadora de íons para quantificação do fósforo disponível, aliando análise básica e granulometria (Física, Textura).', 'Macronutrientes + Textura + Fósforo Remanescente (Pres).', NULL, 'Física Completa (Argila, Silte e Areia).', ARRAY['Profundidades de 0-20, 20-40 cm', 'Lavoura (Demais culturas)', 'Áreas com histórico de Física']::text[], '', '', false, true, 70),
  ('solo-completa-sem-textura', 'solo', 'package', 'Completa s/ Textura', 100.00, 'Subsuperfície', 'cyan', 'Excelente para talhões de lavoura que já possuem mapa textural consolidado. Oferece análise química completa (macro, micro e enxofre) sem custo de granulometria (Física, Textura).', 'Macronutrientes + Enxofre + Micronutrientes completos.', 'Boro, Cobre, Ferro, Manganês, Zinco.', 'Sem física (ideal para perfil 20-40 cm).', ARRAY['Perfil 20-40 cm', 'Lavoura', 'Áreas com histórico de física']::text[], '', '', false, true, 80),
  ('solo-completa-sem-textura-prem', 'solo', 'package', 'Completa s/ Textura + Prem ou Pres', 130.00, 'Alta Resolução', 'gold', 'Para manejo fosfatado avançado em áreas com textura já conhecida. Combina micronutrientes completos, enxofre e Fósforo Remanescente (P-Rem) ou P em Resina.', 'Macronutrientes + Enxofre + Micronutrientes + Prem ou Pres.', 'Boro, Cobre, Ferro, Manganês e Zinco.', 'Sem física (ideal para perfil 20-40 cm).', ARRAY['Profundidades de 0-20, 20-40 cm', 'Lavoura (Demais culturas)', 'Áreas com histórico de Física']::text[], '', '', false, true, 90),
  ('laudo-interpretado', 'solo', 'package', 'Laudo Interpretado + Gráficos', 25.00, 'Serviço Adicional', 'emerald', 'Serviço complementar de inteligência agronômica: laudo traduzido em gráficos visuais de equilíbrio entre bases, relações de cátions e histórico comparativo com anos anteriores.', 'Interpretação agronômica especializada de qualquer laudo de fertilidade.', 'Relatório de equilíbrio de cátions.', 'Gráficos comparativos de safras e anos anteriores.', ARRAY['Tomada de decisão', 'Apresentação para agrônomos']::text[], 'Para produtores, consultorias e agrônomos que desejam visualização executiva.', 'Gera gráficos em radar do equilíbrio de cátions (Ca/Mg/K na CTC) e comparação histórica com safras passadas para tomadas de decisão ágeis.', false, true, 100),
  ('solo-extra-1', 'solo', 'extra', 'Macronutrientes (Química Isolada)', 48.00, NULL, 'slate', 'Determina apenas pH, P, K, Ca, Mg, Al, H+Al, CTC e V% para checagem rápida de calagem e adubação básica.', NULL, NULL, NULL, '{}'::text[], 'Quando você já tem a textura física e micronutrientes consolidados do ano anterior.', 'Determina apenas pH, P, K, Ca, Mg, Al, H+Al, CTC e V% para checagem rápida de calagem e adubação básica.', false, true, 1010),
  ('solo-extra-2', 'solo', 'extra', 'Micronutrientes s/ Boro', 55.00, NULL, 'slate', 'Quantificação espectrométrica de Cobre, Ferro, Manganês e Zinco disponíveis no solo.', NULL, NULL, NULL, '{}'::text[], 'Para monitorar os cátions metálicos (Cu, Fe, Mn, Zn) onde o boro já é manejado via foliar.', 'Quantificação espectrométrica de Cobre, Ferro, Manganês e Zinco disponíveis no solo.', false, true, 1020),
  ('solo-extra-3', 'solo', 'extra', 'Boro Isolado', 45.00, NULL, 'slate', 'Determinação por água quente com azometina-H, o método padrão para quantificar boro solúvel.', NULL, NULL, NULL, '{}'::text[], 'Solos arenosos ou lavouras com alto risco de lixiviação de boro (soja/algodão/café).', 'Determinação por água quente com azometina-H, o método padrão para quantificar boro solúvel.', false, true, 1030),
  ('solo-extra-4', 'solo', 'extra', 'Enxofre Isolado', 42.00, NULL, 'slate', 'Extração com fosfato monocálcico para quantificar o sulfato acumulado no perfil do solo.', NULL, NULL, NULL, '{}'::text[], 'Amostragens em subsuperfície (20-40 cm e 40-60 cm) para cálculo de gessagem.', 'Extração com fosfato monocálcico para quantificar o sulfato acumulado no perfil do solo.', false, true, 1040),
  ('solo-extra-5', 'solo', 'extra', 'Fósforo em Resina', 45.00, NULL, 'slate', 'Extração por resina trocadora de íons, simulando a absorção do nutriente pela raiz da planta.', NULL, NULL, NULL, '{}'::text[], 'Áreas sob plantio direto com longo histórico de adubação ou calibração pelo método IAC.', 'Extração por resina trocadora de íons, simulando a absorção do nutriente pela raiz da planta.', false, true, 1050),
  ('solo-extra-6', 'solo', 'extra', 'Fósforo Remanescente (P-Rem)', 45.00, NULL, 'slate', 'Avalia a capacidade tampão do solo, orientando a dosagem exata de adubação fosfatada sem desperdício.', NULL, NULL, NULL, '{}'::text[], 'Solos muito argilosos ou oxídicos do Cerrado para medir a capacidade de fixação de fósforo.', 'Avalia a capacidade tampão do solo, orientando a dosagem exata de adubação fosfatada sem desperdício.', false, true, 1060),
  ('solo-extra-7', 'solo', 'extra', 'Granulometria Isolada (Física, Textura)', 45.00, NULL, 'slate', 'Determina as porcentagens de Argila, Silte e Areia (método densímetro de Bouyoucos ou pipeta).', NULL, NULL, NULL, '{}'::text[], 'Abertura de novas áreas ou mapeamento textural definitivo de talhões.', 'Determina as porcentagens de Argila, Silte e Areia (método densímetro de Bouyoucos ou pipeta).', false, true, 1070),
  ('solo-extra-8', 'solo', 'extra', 'Nitrogênio Total', 45.00, NULL, 'slate', 'Quantifica o N total por digestão micro-Kjeldahl para balanço de nitrogênio do sistema solo-planta.', NULL, NULL, NULL, '{}'::text[], 'Monitoramento de estoque de matéria orgânica e palhada em plantio direto ou consórcios.', 'Quantifica o N total por digestão micro-Kjeldahl para balanço de nitrogênio do sistema solo-planta.', false, true, 1080),
  ('solo-extra-9', 'solo', 'extra', 'Determinações Isol. em Solo', 40.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1090),
  ('solo-extra-10', 'solo', 'extra', 'Completa + Nitrogênio', 160.00, NULL, 'slate', 'Reúne toda a química completa, granulometria (Física, Textura), micronutrientes e o teor de N Total.', NULL, NULL, NULL, '{}'::text[], 'Para pesquisas agronômicas, auditorias e avaliação de manejo biológico e palhada.', 'Reúne toda a química completa, granulometria (Física, Textura), micronutrientes e o teor de N Total.', false, true, 1100),
  ('solo-extra-11', 'solo', 'extra', 'Sugestão de Adubação e Calagem', 100.00, NULL, 'slate', 'Prescrição agronômica personalizada com base na expectativa de produtividade da sua cultura.', NULL, NULL, NULL, '{}'::text[], 'Produtor que deseja a recomendação técnica pronta com doses de calcário, gesso e formulações NPK.', 'Prescrição agronômica personalizada com base na expectativa de produtividade da sua cultura.', false, true, 1110),
  ('solo-extra-12', 'solo', 'extra', 'Solo Básica + Sugestão Técnica', 150.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1120),
  ('solo-extra-13', 'solo', 'extra', 'Solo Completa + Sugestão Técnica', 210.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1130),
  ('solo-extra-14', 'solo', 'extra', 'Solo Max + Sugestão Técnica', 235.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1140),
  ('solo-extra-15', 'solo', 'extra', 'Solo Max Plus + Sugestão Técnica', 250.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1150),
  ('solo-extra-16', 'solo', 'extra', 'Solo Básica Interpretado', 90.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1160),
  ('solo-extra-17', 'solo', 'extra', 'Solo Completa Interpretado', 145.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1170),
  ('solo-extra-18', 'solo', 'extra', 'Solo Max Interpretado', 175.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1180),
  ('solo-extra-19', 'solo', 'extra', 'Solo Max Plus Interpretado', 200.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1190),
  ('foliar-sem-boro', 'foliar', 'package', 'Foliar Completa s/ Boro', 110.00, 'Padrão', 'slate', 'Indicada para monitoramento nutricional em fases de desenvolvimento vegetativo onde o boro não é limitante ou já é monitorado à parte.', 'Fósforo, Potássio, Cálcio, Magnésio, Enxofre.', 'Cobre, Ferro, Manganês, Zinco.', 'Tecido foliar seco.', ARRAY['Acompanhamento de safra', 'Equilíbrio de pulverização']::text[], '', '', false, true, 10),
  ('foliar-completa', 'foliar', 'package', 'Foliar Completa', 135.00, 'Mais Vendido', 'emerald', 'A análise foliar padrão ouro para soja, milho, algodão, feijão e café. Permite identificar carências nutricionais ocultas e calibrar adubações foliares a tempo.', 'Fósforo, Potássio, Cálcio, Magnésio, Enxofre.', 'Cobre, Ferro, Manganês, Zinco, Boro completo.', 'Tecido foliar padrão.', ARRAY['Diagnóstico do estado nutricional', 'Correção em fertirrigação / foliar']::text[], 'Coleta no estádio vegetativo/reprodutivo (ex: R1/R2 na soja, V4/V6 no milho).', 'Diagnostica carências invisíveis de macro e micronutrientes (N, P, K, Ca, Mg, S, B, Cu, Fe, Mn, Zn) a tempo de aplicar adubação corretiva foliar na mesma safra.', true, true, 20),
  ('foliar-dris', 'foliar', 'package', 'Foliar Completa c/ DRIS', 160.00, 'Diagnóstico DRIS', 'cyan', 'Manejo nutricional de precisão máxima. O sistema DRIS compara as relações mútuas entre nutrientes e aponta a ordem exata de deficiência ou excesso na planta.', 'Fósforo, Potássio, Cálcio, Magnésio, Enxofre.', 'Cobre, Ferro, Manganês, Zinco, Boro.', 'Índice DRIS calculado por balanço nutricional.', ARRAY['Avaliação de equilíbrio entre nutrientes', 'Identificação de excessos e faltas']::text[], 'Para lavouras de alta performance onde os teores isolados parecem normais, mas a planta não atinge o teto produtivo.', 'O Sistema Integrado de Diagnose e Recomendação (DRIS) calcula os balanços nutricionais entre todos os elementos, apontando a ordem exata de deficiência ou excesso limitante.', true, true, 30),
  ('foliar-planta-inteira', 'foliar', 'package', 'Foliar (Planta Inteira)', 180.00, 'Biomassa', 'slate', 'Indicada para curvas de marcha de absorção e extração total de nutrientes, quantificando o peso e o acúmulo de biomassa da raiz às folhas.', 'Fósforo, Potássio, Cálcio, Magnésio, Enxofre.', 'Cobre, Ferro, Manganês, Zinco, Boro.', 'Matéria Seca e Peso de Planta.', ARRAY['Avaliação Nutricional através do Equilíbrio de Nutrientes', 'Acúmulo total na planta']::text[], 'Coleta no estádio vegetativo/reprodutivo (ex: R1/R2 na soja, V4/V6 no milho).', 'Diagnostica carências invisíveis de macro e micronutrientes (N, P, K, Ca, Mg, S, B, Cu, Fe, Mn, Zn) a tempo de aplicar adubação corretiva foliar na mesma safra.', false, true, 40),
  ('peciolo-completa', 'foliar', 'package', 'Pecíolo Completa', 150.00, 'Interpretado', 'slate', 'Especialmente calibrada para cafeeiro, videiras e hortaliças. O pecíolo reflete com maior rapidez o fluxo de seiva e carências imediatas da cultura.', 'Fósforo, Potássio, Cálcio, Magnésio, Enxofre.', 'Cobre, Ferro, Manganês, Zinco, Boro.', 'Resultado interpretado especializado.', ARRAY['Videiras, cafeeiro e hortifruti', 'Monitoramento em tempo real']::text[], 'Para culturas onde o pecíolo expressa com maior rapidez o fluxo nutricional da seiva.', 'Análise interpretada com calibração específica para cafezais, videiras e hortifrúti.', false, true, 50),
  ('analise-graos', 'foliar', 'package', 'Análise de Grãos', 170.00, 'Grãos & Sementes', 'gold', 'Para checagem da qualidade nutricional e comercial pós-colheita (soja, milho, sorgo). Avalia Proteína Bruta, Óleo (Extrato Etéreo) e exportação de nutrientes.', 'Fósforo, Potássio, Cálcio, Magnésio, Enxofre.', 'Cobre, Ferro, Manganês, Zinco, Boro.', 'Proteína Bruta, Extrato Etéreo (Óleo).', ARRAY['Qualidade industrial de colheita', 'Exportação e sementeiras']::text[], 'Auditoria pós-colheita e controle de sementes comerciais.', 'Mede a exportação real de nutrientes da lavoura somada aos teores de Proteína Bruta e Extrato Etéreo (óleo).', false, true, 60),
  ('sal-mineral-basica', 'foliar', 'package', 'Sal Mineral Básica', 190.00, 'Mineral Básico', 'slate', 'Conferência rápida dos macrominerais essenciais de suplementos para rebanho de corte ou leite: Nitrogênio, Fósforo, Cálcio, Potássio e Sódio.', 'Nitrogênio, Fósforo, Cálcio, Potássio, Sódio.', 'Determinações isoladas disponíveis.', 'Suplemento mineral para rebanho.', ARRAY['Garantia de macrominerais básicos', 'Checagem de formulação']::text[], '', '', false, true, 70),
  ('sal-mineral-completo', 'foliar', 'package', 'Sal Mineral Completo', 300.00, 'Pecuária Top', 'gold', 'Auditoria técnica rigorosa de sais comerciais. Inclui solubilidade do fósforo em ácido cítrico (biodisponibilidade) e todos os micronutrientes.', 'N, P, P em Ácido Cítrico (Solubilidade), K, Na, Ca, Mg, S.', 'Cu, Ferro, Manganês, Zinco, Boro.', 'Solubilidade e garantia de rótulo mineral.', ARRAY['Suplementação mineral', 'Controle de fórmulas pecuárias']::text[], '', '', false, true, 80),
  ('sal-proteinado', 'foliar', 'package', 'Sal Proteinado', 420.00, 'Suplemento', 'slate', 'Avaliação completa para proteinados de seca ou de águas: perfil mineral amplo somado a Proteína Bruta, NDT, Umidade, Fibra Bruta e Matéria Mineral.', 'Nitrogênio, Fósforo, P Ácido Cítrico, K, Na, Ca, Mg, S.', 'Cu, Ferro, Manganês, Zinco, Boro.', 'Proteína Bruta, Fibra Bruta, Extrato Etéreo, Cinzas, NDT, ENN, Umidade.', ARRAY['Proteinado de águas e seca', 'Ganho de peso bovino']::text[], '', '', false, true, 90),
  ('bromatologica-basica', 'foliar', 'package', 'Bromatológica Básica', 140.00, 'Nutrição Animal', 'emerald', 'Controle de rotina da composição de volumosos e forragens: Umidade, Proteína Bruta, Extrato Etéreo, Cálcio e Fósforo.', 'Cálcio, Fósforo.', 'Umidade, Proteína Bruta, Extrato Etéreo.', 'Alimentos concentrados e forragens.', ARRAY['Formulação de ração', 'Avaliação de silagem']::text[], '', '', false, true, 100),
  ('bromatologica-completa', 'foliar', 'package', 'Bromatológica Completa', 200.00, 'Nutrição Ruminantes', 'cyan', 'Obrigatória para dimensionamento de dietas em confinamentos e bacia leiteira. Fornece Nutrientes Digestíveis Totais (NDT), Matéria Mineral e Fibra Bruta.', 'Cálcio, Fósforo, Cinzas (Matéria Mineral).', 'Umidade, Proteína Bruta, Fibra Bruta, Extrato Etéreo.', 'Nutrientes Digestíveis Totais (NDT), Extrato Não Nitrogenado.', ARRAY['Bovinocultura de corte e leite', 'Controle de qualidade de silagens']::text[], 'Para formulação precisa de dietas em confinamentos, silagens de milho/sorgo e rebanhos leiteiros.', 'A Completa determina Nutrientes Digestíveis Totais (NDT), Proteína Bruta, Extrato Etéreo e Cinzas. A Max Plus adiciona FDN e FDA para medição exata do consumo e digestibilidade da forragem.', true, true, 110),
  ('bromatologica-max-plus', 'foliar', 'package', 'Bromatológica Max Plus', 300.00, 'Alto Desempenho', 'gold', 'A mais detalhada análise bromatológica para pecuária de elite. Adiciona FDN e FDA para determinação precisa da taxa de passagem e digestibilidade.', 'Cálcio, Fósforo, Matéria Mineral completa.', 'Proteína Bruta, Fibra Bruta, Extrato Etéreo, NDT, ENN.', 'Determinação de FDN e FDA inclusos.', ARRAY['Dietas de confinamento', 'Digestibilidade e consumo animal']::text[], '', '', false, true, 120),
  ('foliar-extra-1', 'foliar', 'extra', 'Umidade em Alimentos/Tecidos', 30.00, NULL, 'slate', 'Secagem em estufa a 65°C/105°C para conversão dos resultados e ajuste de ingestão de matéria seca.', NULL, NULL, NULL, '{}'::text[], 'Determinação de matéria seca em silagens, pastos verdes, rações e grãos colhidos.', 'Secagem em estufa a 65°C/105°C para conversão dos resultados e ajuste de ingestão de matéria seca.', false, true, 1010),
  ('foliar-extra-2', 'foliar', 'extra', 'DRIS Foliar Adicional (Consultar Cultura)', 50.00, NULL, 'slate', 'Calcula os índices de equilíbrio e o Índice de Balanço Nutricional Médio (IBNm).', NULL, NULL, NULL, '{}'::text[], 'Quando você contratou uma foliar comum e deseja gerar o diagnóstico por índices DRIS.', 'Calcula os índices de equilíbrio e o Índice de Balanço Nutricional Médio (IBNm).', false, true, 1020),
  ('foliar-extra-3', 'foliar', 'extra', 'Monensina', 120.00, NULL, 'slate', 'Verifica a concentração do aditivo para assegurar eficiência ruminal e evitar dosagens tóxicas.', NULL, NULL, NULL, '{}'::text[], 'Auditoria de ionóforos em rações concentradas para confinamento ou creep feeding.', 'Verifica a concentração do aditivo para assegurar eficiência ruminal e evitar dosagens tóxicas.', false, true, 1030),
  ('foliar-extra-4', 'foliar', 'extra', 'Foliar Completa + Bromatológica', 300.00, NULL, 'slate', 'Integra o estado nutricional da planta (fertilidade do pasto) com o valor alimentar para o gado.', NULL, NULL, NULL, '{}'::text[], 'Manejo nutricional completo de pastagens (Brachiaria, Panicum) e forragens verdes.', 'Integra o estado nutricional da planta (fertilidade do pasto) com o valor alimentar para o gado.', false, true, 1040),
  ('foliar-extra-5', 'foliar', 'extra', 'FDN (Fibra em Detergente Neutro)', 50.00, NULL, 'slate', 'Determina a fração fibrosa de digestão lenta (hemicelulose, celulose e lignina).', NULL, NULL, NULL, '{}'::text[], 'Avaliação da capacidade de consumo voluntário de forragem pelos bovinos.', 'Determina a fração fibrosa de digestão lenta (hemicelulose, celulose e lignina).', false, true, 1050),
  ('foliar-extra-6', 'foliar', 'extra', 'FDA (Fibra em Detergente Ácido)', 55.00, NULL, 'slate', 'Quantifica a lignina e celulose para predizer a digestibilidade real da dieta pecuária.', NULL, NULL, NULL, '{}'::text[], 'Medição da fração indigestível e cálculo da energia líquida da silagem/forragem.', 'Quantifica a lignina e celulose para predizer a digestibilidade real da dieta pecuária.', false, true, 1060),
  ('foliar-extra-7', 'foliar', 'extra', 'Ureia', 50.00, NULL, 'slate', 'Previne subdosagens ineficazes ou superdosagens fatais com risco de intoxicação no rebanho.', NULL, NULL, NULL, '{}'::text[], 'Checagem de lotes de sais proteinados, suplementos de seca e rações concentradas.', 'Previne subdosagens ineficazes ou superdosagens fatais com risco de intoxicação no rebanho.', false, true, 1070),
  ('foliar-extra-8', 'foliar', 'extra', 'Sal Mineral: Determinação Isolada', 40.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1080),
  ('foliar-extra-9', 'foliar', 'extra', 'Sal Mineral: Boro Isolado', 45.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1090),
  ('foliar-extra-10', 'foliar', 'extra', 'Cobalto (Co)', 60.00, NULL, 'slate', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', NULL, NULL, NULL, '{}'::text[], 'Nutrição de reprodutores de elite, bovinos de alto valor zootécnico e premixes minerais.', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', false, true, 1100),
  ('foliar-extra-11', 'foliar', 'extra', 'Cromo (Cr)', 90.00, NULL, 'slate', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', NULL, NULL, NULL, '{}'::text[], 'Nutrição de reprodutores de elite, bovinos de alto valor zootécnico e premixes minerais.', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', false, true, 1110),
  ('foliar-extra-12', 'foliar', 'extra', 'Níquel (Ni)', 90.00, NULL, 'slate', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', NULL, NULL, NULL, '{}'::text[], 'Nutrição de reprodutores de elite, bovinos de alto valor zootécnico e premixes minerais.', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', false, true, 1120),
  ('foliar-extra-13', 'foliar', 'extra', 'Molibdênio (Mo)', 80.00, NULL, 'slate', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', NULL, NULL, NULL, '{}'::text[], 'Nutrição de reprodutores de elite, bovinos de alto valor zootécnico e premixes minerais.', 'Quantificação por espectrometria de elementos essenciais envolvidos na síntese de vitamina B12 e metabolismo.', false, true, 1130),
  ('foliar-extra-14', 'foliar', 'extra', 'Nitrogênio Não Proteico (NNP)', 70.00, NULL, 'slate', 'Mede o nitrogênio solúvel disponível para conversão microbiana em proteína metabolizável.', NULL, NULL, NULL, '{}'::text[], 'Balanceamento preciso de dietas com fontes alternativas de nitrogênio para bactérias ruminais.', 'Mede o nitrogênio solúvel disponível para conversão microbiana em proteína metabolizável.', false, true, 1140),
  ('foliar-extra-15', 'foliar', 'extra', 'Teste de Homogeneidade (Até 10 testes)', 250.00, NULL, 'slate', 'Avalia o Coeficiente de Variação (CV%) do lote, garantindo que todo animal consuma a mesma fórmula.', NULL, NULL, NULL, '{}'::text[], 'Auditoria periódica de misturadores da fábrica de ração ou do vagão forrageiro da fazenda.', 'Avalia o Coeficiente de Variação (CV%) do lote, garantindo que todo animal consuma a mesma fórmula.', false, true, 1150),
  ('adubo-mineral-basica', 'fertilizantes', 'package', 'Adubo Mineral Básica', 125.00, 'Básico NPK', 'slate', 'Para checagem rápida de conformidade em cargas comerciais recebidas na fazenda, verificando a garantia dos teores de Nitrogênio, Fósforo e Potássio (NPK).', 'Nitrogênio, Fósforo, Potássio (Garantia NPK).', NULL, 'Teor de ativos solúveis.', ARRAY['Checagem de formulações comerciais de adubo']::text[], '', '', false, true, 10),
  ('adubo-mineral-completa', 'fertilizantes', 'package', 'Adubo Mineral Completa', 280.00, 'Completo', 'emerald', 'Auditoria completa de formulados químicos enriquecidos: certifica NPK mais macronutrientes secundários (Ca, Mg, S) e micronutrientes (B, Cu, Fe, Mn, Zn).', 'Nitrogênio, Fósforo CNA, Potássio, Cálcio, Magnésio, Enxofre.', 'Boro, Cobre, Ferro, Manganês, Zinco.', 'Homogeneidade do adubo mineral.', ARRAY['Validação de cargas comerciais e fornecedores']::text[], '', '', true, true, 20),
  ('adubo-mineral-max-plus', 'fertilizantes', 'package', 'Adubo Mineral Max Plus', 340.00, 'Máxima Solubilidade', 'gold', 'O mais rigoroso controle de fertilizantes minerais: determina solubilidade do fósforo em água e ácido cítrico, além de análise de granulometria (Física, Textura) em peneiras.', 'Nitrogênio, Fósforo CNA, Fósforo em Ác. Cítrico (Solubilidade), Potássio, Ca, Mg, S.', 'B, Cu, Fe, Mn, Zn.', 'Análise de Granulometria (Física, Textura) por Peneiras inclusa.', ARRAY['Auditoria técnica rigorosa de fertilizantes']::text[], '', '', false, true, 30),
  ('adubo-organomineral-max', 'fertilizantes', 'package', 'Adubo Organomineral Max Plus', 500.00, 'Prêmio Premium', 'gold', 'Laudo completo para organominerais e biofertilizantes: todas as frações de P e K, extratos húmicos e fúlvicos, carbono orgânico, CTC e granulometria (Física, Textura).', 'Nitrogênio, Fósforo Total, P CNA, P Ác. Cítrico, P Água, K Total e em Água, Mg, Enxofre.', 'Boro Total e Ác. Cítrico, Cu, Fe, Mn, Zn.', 'Matéria Orgânica, C Orgânico, CTC, C/N, pH, Extratos Húmicos e Fúlvicos, Granulometria (Física, Textura).', ARRAY['Certificação completa de organominerais e biofertilizantes']::text[], '', '', true, true, 40),
  ('adubo-organico-basica', 'fertilizantes', 'package', 'Adubo Orgânico Básica', 140.00, 'Compostagem', 'slate', 'Para monitoramento de compostagem, estercos curtidos e camas de aviário: avalia NPK, teor de umidade, matéria orgânica e resíduo mineral.', 'Nitrogênio, Fósforo, Potássio.', 'Matéria Orgânica, Umidade, Material Mineral.', 'Teor de umidade e matéria orgânica.', ARRAY['Esterco, cama de frango e composto orgânico']::text[], '', '', false, true, 50),
  ('adubo-organico-completo', 'fertilizantes', 'package', 'Adubo Orgânico Completo', 300.00, 'Completo Orgânico', 'emerald', 'Laudo detalhado de fertilizantes orgânicos e biossólidos: determina teores totais e assimiláveis de macro, micronutrientes, matéria orgânica e carbono orgânico.', 'N, P CNA, P Ácido Cítrico, Potássio, Cálcio, Magnésio, Enxofre.', 'Boro, Cobre, Ferro, Manganês, Zinco.', 'Matéria Orgânica, Carbono Orgânico, Umidade.', ARRAY['Compostos maturados e biossólidos']::text[], '', '', false, true, 60),
  ('adubo-organico-max-plus', 'fertilizantes', 'package', 'Adubo Orgânico Max Plus', 370.00, 'Completo Orgânico Plus', 'gold', 'Máxima caracterização para bioinsumos e compostos orgânicos de alta qualidade: mede CTC, relação C/N, pH, umidade e todos os nutrientes.', 'N, P CNA, Potássio, Cálcio, Magnésio, Enxofre.', 'Boro, Cobre, Ferro, Manganês, Zinco.', 'Matéria Orgânica, Carb. Orgânico, Umidade, CTC, pH, Relação C/N.', ARRAY['Compostos maturados e biofertilizantes avançados']::text[], '', '', false, true, 70),
  ('calcario-basico', 'fertilizantes', 'package', 'Calcário Básico', 70.00, 'Corretivo', 'slate', 'Imprescindível para o cálculo agronômico de calagem: determina teores de CaO, MgO, Poder de Neutralização (PN), PRNT e classificação granulométrica.', 'CaO (Óxido de Cálcio), MgO (Óxido de Magnésio).', NULL, 'PN (Poder de Neutralização), PRNT e Granulometria (Física, Textura).', ARRAY['Cálculo real de calagem por PRNT']::text[], 'Ao descarregar calcário na fazenda para certificar o PRNT contratado.', 'O Básico mede CaO, MgO, Poder de Neutralização (PN), PRNT e granulometria (Física, Textura). O Completo adiciona sílica, insolúveis e resíduo insolúvel (RI) para identificar contaminação por terra ou impurezas.', false, true, 80),
  ('calcario-completa', 'fertilizantes', 'package', 'Calcário Completo', 130.00, 'Qualidade Total', 'cyan', 'Auditoria avançada de pureza do calcário agrícola: adiciona ensaios de sílica, insolúveis e resíduo insolúvel (RI) para identificar contaminações minerais.', 'CaO, MgO, PN, PRNT, Granulometria (Física, Textura).', NULL, 'Umidade, Insolúveis, Sílica e Resíduo Insolúvel (RI).', ARRAY['Inspeção de pureza contra contaminação por sílica']::text[], '', '', false, true, 90),
  ('gesso-agricola', 'fertilizantes', 'package', 'Gesso Agrícola', 70.00, 'Condicionador', 'emerald', 'Para verificação do condicionador de subsolo: garante os teores solúveis de Cálcio (Ca), Enxofre (S) e o teor de umidade da carga entregue.', 'Enxofre (S), Cálcio (Ca).', NULL, 'Umidade e teor de pureza.', ARRAY['Condicionamento de subsuperfície e fornecimento de Enxofre']::text[], 'Para garantir os teores de Cálcio, Enxofre e umidade da carga de gesso.', 'Certifica a pureza e o teor ativo de Ca e S solúveis para aplicação segura no perfil do solo.', false, true, 100),
  ('fertilizantes-extra-1', 'fertilizantes', 'extra', 'Umidade em Fertilizantes/Corretivos', 30.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1010),
  ('fertilizantes-extra-2', 'fertilizantes', 'extra', 'Granulometria (Física, Textura) por Peneiras', 45.00, NULL, 'slate', 'Ensaio mecânico de peneiramento com cálculo de finura e uniformidade dos grânulos.', NULL, NULL, NULL, '{}'::text[], 'Conferência da curva granulométrica de adubos granulados ou farelados para regulagem de plantadeiras.', 'Ensaio mecânico de peneiramento com cálculo de finura e uniformidade dos grânulos.', false, true, 1020),
  ('fertilizantes-extra-3', 'fertilizantes', 'extra', 'Preparação de Amostra Específica', 40.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1030),
  ('fertilizantes-extra-4', 'fertilizantes', 'extra', 'Metais Pesados (Pb, Cr, Ni, Cd - Isolado)', 100.00, NULL, 'slate', 'Ensaio toxicológico por espectrometria atômica para conformidade com os limites máximos do MAPA.', NULL, NULL, NULL, '{}'::text[], 'Auditoria de compostos orgânicos, lodos de esgoto, pós de rocha e fertilizantes minerais.', 'Ensaio toxicológico por espectrometria atômica para conformidade com os limites máximos do MAPA.', false, true, 1040),
  ('fertilizantes-extra-5', 'fertilizantes', 'extra', 'Sílica + Resíduo Insolúvel (RI)', 70.00, NULL, 'slate', 'Identifica a presença de materiais inertes que aumentam o custo do frete sem neutralizar o solo.', NULL, NULL, NULL, '{}'::text[], 'Auditoria de calcário moído para verificar contaminação por terra, argila ou areia estéril.', 'Identifica a presença de materiais inertes que aumentam o custo do frete sem neutralizar o solo.', false, true, 1050),
  ('fertilizantes-extra-6', 'fertilizantes', 'extra', 'Enxofre (Determinação Isolada)', 60.00, NULL, 'slate', 'Quantificação gravimétrica ou turbidimétrica do enxofre ativo disponível.', NULL, NULL, NULL, '{}'::text[], 'Auditoria de sulfato de amônio, gesso ou fontes concentradas de enxofre elementar.', 'Quantificação gravimétrica ou turbidimétrica do enxofre ativo disponível.', false, true, 1060),
  ('fertilizantes-extra-7', 'fertilizantes', 'extra', 'Extrato Húmico e Fúlvico', 160.00, NULL, 'slate', 'Fracionamento de substâncias húmicas para atestar o potencial de ativação radicular do insumo.', NULL, NULL, NULL, '{}'::text[], 'Certificação de ácidos húmicos, fúlvicos e bioestimulantes à base de leonardita e turfa.', 'Fracionamento de substâncias húmicas para atestar o potencial de ativação radicular do insumo.', false, true, 1070),
  ('fertilizantes-extra-8', 'fertilizantes', 'extra', 'Adubo Orgânico Básica + Húmico e Fúlvico', 290.00, NULL, 'slate', 'Combo econômico com todas as garantias essenciais de compostagem de alta tecnologia.', NULL, NULL, NULL, '{}'::text[], 'Avaliação simultânea de NPK + matéria orgânica + frações húmicas em compostos e estercos.', 'Combo econômico com todas as garantias essenciais de compostagem de alta tecnologia.', false, true, 1080),
  ('fertilizantes-extra-9', 'fertilizantes', 'extra', 'Gesso + CaO, Mg, P, K, B, Cu, Fe, Mn, Zn', 340.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1090),
  ('fertilizantes-extra-10', 'fertilizantes', 'extra', 'Adubo Líquido: Densidade', 50.00, NULL, 'slate', 'Mede o peso específico (g/mL) e a Capacidade de Troca Catiônica de adubos solúveis.', NULL, NULL, NULL, '{}'::text[], 'Conferência de fertilizantes fluidos, caldas nutritivas e fertilizantes de fertirrigação.', 'Mede o peso específico (g/mL) e a Capacidade de Troca Catiônica de adubos solúveis.', false, true, 1100),
  ('fertilizantes-extra-11', 'fertilizantes', 'extra', 'Adubo Líquido: CTC', 60.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1110),
  ('fertilizantes-extra-12', 'fertilizantes', 'extra', 'Adubo Mineral: Determinações Isoladas', 45.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1120),
  ('fertilizantes-extra-13', 'fertilizantes', 'extra', 'Adubo Mineral: Boro, P Total, CNA ou Água (cada)', 50.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1130),
  ('fertilizantes-extra-14', 'fertilizantes', 'extra', 'Adubo Orgânico: Determinações Isoladas', 45.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1140),
  ('fertilizantes-extra-15', 'fertilizantes', 'extra', 'Adubo Orgânico: Carbono Orgânico', 50.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1150),
  ('fertilizantes-extra-16', 'fertilizantes', 'extra', 'Adubo Orgânico: Fósforo Total ou Boro', 50.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1160),
  ('fertilizantes-extra-17', 'fertilizantes', 'extra', 'Adubo Orgânico: Silício', 60.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1170),
  ('fertilizantes-extra-18', 'fertilizantes', 'extra', 'Adubo Orgânico: CTC', 60.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1180),
  ('fertilizantes-extra-19', 'fertilizantes', 'extra', 'Calcário: Determinação Isolada', 45.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1190),
  ('fertilizantes-extra-20', 'fertilizantes', 'extra', 'Gesso Agrícola: Determinação Isolada', 50.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1200),
  ('bioas-basica', 'bioas', 'package', 'BioAS Básica', 215.00, 'BioAS Embrapa', 'emerald', 'Tecnologia BioAS Embrapa aliada à fertilidade química básica e textura. Mede as enzimas Arilsulfatase e Betaglicosidase, gerando o IQS Biológico, Químico e Fertbio.', 'pH CaCl2, P (Mehlich), K, Na, Ca, Mg, Al, H+Al, S, CTC, Saturações, M.O., C Orgânico.', NULL, 'Granulometria (Física, Textura) (Argila, Silte, Areia).', ARRAY['Enzimas Arilsulfatase e Betaglicosidase', 'IQS Biológico, Químico e IQS Fertbio']::text[], '', '', false, true, 10),
  ('bioas-completa', 'bioas', 'package', 'BioAS Completa', 265.00, 'Mais Completo', 'emerald', 'O diagnóstico biológico mais procurado para lavouras de alta performance. Reúne a bioanálise enzimática BioAS completa, todos os micronutrientes e textura física.', 'pH CaCl2, P (Mehlich), K, Na, Ca, Mg, Al, H+Al, S, CTC, Saturações, M.O., C Orgânico.', 'Boro, Cobre, Ferro, Manganês, Zinco.', 'Granulometria Completa (Física, Textura).', ARRAY['BioAS Completa com IQS Biológico, Químico e Fertbio']::text[], 'Para monitorar a saúde do solo e o efeito de rotação de culturas, plantas de cobertura e bioinsumos.', 'Mede a atividade das enzimas Arilsulfatase (ciclo do enxofre) e Betaglicosidase (ciclo do carbono), gerando os índices IQS Biológico, Químico e Fertbio com laudo químico e textural completo.', true, true, 20),
  ('bioas-max', 'bioas', 'package', 'BioAS Max', 280.00, 'BioAS + Resina', 'cyan', 'Indicada para solos sob rotação intensiva e bioinsumos com necessidade de quantificar Fósforo Remanescente (P-Rem) ou P em Resina associados à biologia do solo.', 'pH CaCl2, pH H2O, P (Mehlich), K, Na, Ca, Mg, Al, CTC, M.O., P Remanescente ou Resina.', 'B, Cu, Fe, Mn, Zinco.', 'Argila, Silte, Areia.', ARRAY['Enzimas Arilsulfatase e Betaglicosidase', 'IQS Fertbio de Alta Resolução']::text[], '', '', false, true, 30),
  ('bioas-max-plus', 'bioas', 'package', 'BioAS Max Plus', 315.00, 'Saúde Máxima do Solo', 'gold', 'A avaliação definitiva da saúde e potencial regenerativo do solo. Mede todas as enzimas BioAS, níveis críticos de nutrientes, frações de fósforo e fertilidade total.', 'pH CaCl2, pH H2O, P (Mehlich), P Remanescente, Níveis Críticos P, S, Zn, K, Na, Ca, Mg, CTC total.', 'Boro, Cobre, Ferro, Manganês, Zinco.', 'Granulometria (Física, Textura) Completa.', ARRAY['Determinação de Arilsulfatase + Betaglicosidase', 'IQS Biológico, Químico e IQS Fertbio completo']::text[], '', '', true, true, 40),
  ('bioas-enzimatica', 'bioas', 'package', 'BioAS Enzimática Isolada', 160.00, 'Exclusivo BioAS', 'slate', 'Para áreas que já contam com laudo químico recente. Determina exclusivamente as enzimas Arilsulfatase e Betaglicosidase, M.O. e física para emissão do IQS Biológico.', 'Matéria Orgânica do solo.', NULL, 'Teor de Argila, Silte e Areia.', ARRAY['Enzimas Arilsulfatase e Betaglicosidase', 'IQS Biológico Embrapa']::text[], '', '', false, true, 50),
  ('nematoides-solo-raiz', 'bioas', 'package', 'Nematoides Solo e Raiz', 140.00, 'Nematologia', 'emerald', 'Fundamental para diagnóstico de reboleiras e queda de produtividade. Identifica e quantifica os gêneros fitoparasitas em amostras de solo e raiz (Pratylenchus, Meloidogyne, etc).', 'Identificação populacional em amostras de solo e sistema radicular.', NULL, 'Contagem de cistos e identificação dos principais gêneros.', ARRAY['Manejo fitossanitário de soja, milho, algodão e cana']::text[], 'Sempre que notar reboleiras amareladas, plantas raquíticas ou perda de produtividade na soja/milho.', 'Identifica e quantifica os gêneros fitoparasitas presentes (Pratylenchus brachyurus, Meloidogyne incognita/javanica, Heterodera glycines, Rotylenchulus reniformis, etc).', false, true, 60),
  ('nematoides-raca', 'bioas', 'package', 'Nematoides + Determinação de Raça', 1400.00, 'Diferenciação Genética', 'gold', 'Ensaio completo com bioensaio em plantas hospedeiras diferenciadoras para identificação da raça fisiológica do nematoide, orientando a escolha exata da cultivar resistente.', 'Mapeamento genético completo da espécie e raça fisiológica do nematoide.', NULL, 'Ensaio em hospedeiras diferenciadoras padrão.', ARRAY['Escolha de cultivares resistentes e rotação de culturas']::text[], 'Para planejamento seguro da próxima safra de soja em áreas com histórico de nematoide do cisto ou galha.', 'Bioensaio completo em hospedeiras diferenciadoras padrão para definir a raça fisiológica e orientar a compra exata de cultivares resistentes.', false, true, 70),
  ('diagnose-doencas', 'bioas', 'package', 'Diagnose de Doenças de Planta', 160.00, 'Fitopatologia', 'cyan', 'Diagnóstico fitopatológico rápido com laudo fotográfico. Identifica fungos e bactérias em tecidos foliares, caules ou raízes sintomáticas para suporte técnico à pulverização.', 'Identificação de fungos e bactérias fitopatogênicas.', NULL, 'Amostras de Caule, Raiz e Folha com laudo fotográfico.', ARRAY['Diagnóstico rápido para tomada de decisão em pulverizações']::text[], 'Aparecimento de manchas, podridões ou queimas em folhas, caules ou raízes.', 'Isolamento microbiológico rápido com laudo fotográfico em microscopia para tomada de decisão imediata em pulverizações.', false, true, 80),
  ('combo-fungos', 'bioas', 'package', 'Combo de Fungos', 460.00, 'Fungos de Solo', 'emerald', 'Pesquisa simultânea dos três principais patógenos radiculares de solo (Fusarium sp + Rhizoctonia sp + Macrophomina phaseolina) causadores de tombamento e podridões.', 'Fusarium sp + Rhizoctonia sp + Macrophomina phaseolina.', NULL, 'Análise em Solo ou Raiz.', ARRAY['Complexo radicular de patógenos', 'Prevenção de podridão radicular']::text[], 'Suspeita de podridões radiculares, tombamento de plântulas ou morte prematura de plantas.', 'Pesquisa simultânea dos três fungos mais destrutivos de solo: Fusarium sp, Rhizoctonia sp e Macrophomina phaseolina em amostras de solo ou raiz.', true, true, 90),
  ('erwinia-bacteria', 'bioas', 'package', 'Erwinia - Bactéria', 230.00, 'Bacteriologia', 'slate', 'Isolamento e diagnóstico bacteriano para confirmação de Erwinia sp., causadora de podridão-mole e canela-preta em batata, cenoura, tomate e folhosas.', 'Isolamento e diagnóstico de Erwinia sp.', NULL, 'Caule, bulbo ou folhas sintomáticas.', ARRAY['Identificação de podridão-mole e canela-preta']::text[], '', '', false, true, 100),
  ('contagem-cisto', 'bioas', 'package', 'Contagem de Cisto', 80.00, 'Nematologia', 'slate', 'Extração e quantificação de cistos viáveis de Heterodera glycines para monitoramento e mapeamento das áreas infestadas pelo nematoide do cisto da soja.', 'Extração e quantificação de cistos de Heterodera glycines.', NULL, 'Solo ou Raiz.', ARRAY['Monitoramento de nematoide de cisto da soja']::text[], '', '', false, true, 110),
  ('determinacao-raca-isolada', 'bioas', 'package', 'Determinação de Raça (Isolada)', 1300.00, 'Genética', 'gold', 'Determinação isolada da raça fisiológica em série diferenciadora de cultivares, indicada quando o nematoide já foi previamente identificado.', 'Ensaio biológico em série diferenciadora de cultivares.', NULL, 'Determinação específica de raça fisiológica.', ARRAY['Seleção de variedades resistentes']::text[], '', '', false, true, 120),
  ('bioas-extra-1', 'bioas', 'extra', 'Trichoderma sp. - Solo ou Raiz (Contagem)', 220.00, NULL, 'slate', 'Isolamento em meio seletivo com contagem de Unidades Formadoras de Colônia (UFC/g de solo).', NULL, NULL, NULL, '{}'::text[], 'Auditoria pós-aplicação de bioinsumos ou verificação de UFCs viáveis do fungo benéfico no perfil radicular.', 'Isolamento em meio seletivo com contagem de Unidades Formadoras de Colônia (UFC/g de solo).', false, true, 1010),
  ('bioas-extra-2', 'bioas', 'extra', 'Sclerotinia sclerotiorum + Sclerotium rolfsii', 220.00, NULL, 'slate', 'Pesquisa de escleródios viáveis no solo e estruturas de resistência antes do plantio.', NULL, NULL, NULL, '{}'::text[], 'Prevenção e mapeamento de risco do mofo-branco e podridão-de-esclerócio em áreas de soja, feijão e algodão.', 'Pesquisa de escleródios viáveis no solo e estruturas de resistência antes do plantio.', false, true, 1020),
  ('bioas-extra-3', 'bioas', 'extra', 'Pythium sp. - Presença/Ausência', 220.00, NULL, 'slate', 'Isolamento e identificação do oomiceto patogênico em plântulas e solo rizosférico.', NULL, NULL, NULL, '{}'::text[], 'Investigação de ''damping-off'' (tombamento de plântulas) e apodrecimento aquoso de radículas em solos encharcados.', 'Isolamento e identificação do oomiceto patogênico em plântulas e solo rizosférico.', false, true, 1030),
  ('bioas-extra-4', 'bioas', 'extra', 'Verticillium sp.', 215.00, NULL, 'slate', 'Isolamento fitopatológico especializado com caracterização morfológica microscópica.', NULL, NULL, NULL, '{}'::text[], 'Murchas vasculares (Verticillium) ou contaminações fúngicas em grãos armazenados e sementes.', 'Isolamento fitopatológico especializado com caracterização morfológica microscópica.', false, true, 1040),
  ('bioas-extra-5', 'bioas', 'extra', 'Aspergillus sp.', 220.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1050),
  ('bioas-extra-6', 'bioas', 'extra', 'Penicillium sp.', 225.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1060),
  ('bioas-extra-7', 'bioas', 'extra', 'Nematoides + Contagem de Cistos', 130.00, NULL, 'slate', 'Combina a extração de juvenis de segundo estágio (J2) com a flotação e contagem de cistos intactos.', NULL, NULL, NULL, '{}'::text[], 'Monitoramento de rotina em áreas com histórico de Nematoide do Cisto da Soja (Heterodera glycines).', 'Combina a extração de juvenis de segundo estágio (J2) com a flotação e contagem de cistos intactos.', false, true, 1070),
  ('bioas-extra-8', 'bioas', 'extra', 'Contagem de Cisto Isolada', 80.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1080),
  ('bioas-extra-9', 'bioas', 'extra', 'Identificação de Espécie de Meloidogyne', 750.00, NULL, 'slate', 'Eletroforese de isoenzimas (esterase) e morfologia do padrão perineal para escolha precisa da semente resistente.', NULL, NULL, NULL, '{}'::text[], 'Para saber exatamente se o nematoide das galhas é M. incognita ou M. javanica.', 'Eletroforese de isoenzimas (esterase) e morfologia do padrão perineal para escolha precisa da semente resistente.', false, true, 1090),
  ('bioas-extra-10', 'bioas', 'extra', 'Diferenciação de Espécie de Pratylenchus', 770.00, NULL, 'slate', 'Morfometria de alta resolução para definir estratégia de rotação com crotalárias e milheto.', NULL, NULL, NULL, '{}'::text[], 'Fundamental no sistema soja-milho para diferenciar Pratylenchus brachyurus de Pratylenchus zeae.', 'Morfometria de alta resolução para definir estratégia de rotação com crotalárias e milheto.', false, true, 1100),
  ('bioas-extra-11', 'bioas', 'extra', 'Patologia de Sementes', 220.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1110),
  ('bioas-extra-12', 'bioas', 'extra', 'Sanidade de Sementes', 170.00, NULL, 'slate', 'Método de papel filtro (Blotter test) com e sem congelamento para detecção de fungos transmitidos por sementes.', NULL, NULL, NULL, '{}'::text[], 'Auditoria pré-semeadura de lotes de sementes comerciais para evitar introduzir fungos na área virgem.', 'Método de papel filtro (Blotter test) com e sem congelamento para detecção de fungos transmitidos por sementes.', false, true, 1120),
  ('bioas-extra-13', 'bioas', 'extra', 'Combo Fungos Solo (Fusarium + Rhizoctonia + Macrophomina)', 460.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1130),
  ('bioas-extra-14', 'bioas', 'extra', 'Nematoide Geral + Fusarium', 600.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1140),
  ('bioas-extra-15', 'bioas', 'extra', 'Nematoide Geral + Espécie Meloidogyne', 850.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1150),
  ('bioas-extra-16', 'bioas', 'extra', 'Nematoide + Fusarium + Rhizoctonia + Macrophomina + Diagnose Doença', 850.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1160),
  ('bioas-extra-17', 'bioas', 'extra', 'Combo Completo: Nematoides + Fungos + Doença', 1500.00, NULL, 'slate', '', NULL, NULL, NULL, '{}'::text[], '', '', false, true, 1170)
on conflict (id) do update set
  category = excluded.category,
  kind = excluded.kind,
  name = excluded.name,
  price = excluded.price,
  badge = excluded.badge,
  badge_color = excluded.badge_color,
  description = excluded.description,
  macronutrientes = excluded.macronutrientes,
  micronutrientes = excluded.micronutrientes,
  granulometria = excluded.granulometria,
  finalidades = excluded.finalidades,
  guide_when = excluded.guide_when,
  guide_detail = excluded.guide_detail,
  highlight = excluded.highlight,
  active = excluded.active,
  sort_order = excluded.sort_order,
  updated_at = now();
