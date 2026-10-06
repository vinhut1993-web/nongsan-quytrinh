-- =====================================================================
-- HỆ THỐNG BÁO GIÁ NÔNG SẢN NHẬP KHẨU — GIAI ĐOẠN 1 — SCHEMA PostgreSQL 15+
-- Quy ước: tiền VNĐ, khối lượng KG, đơn giá NCC USD/KG, phí VNĐ/TẤN.
-- Quy trình: Khách gửi yêu cầu (mặt hàng, cảng, quy cách, số lượng)
--   -> lấy báo giá nhiều NCC cho từng dòng yêu cầu -> tính giá vốn, phụ phí, VAT
--   -> so sánh tổng sau VAT theo số lượng khách cần -> chọn NCC tối ưu gửi khách
-- (Giai đoạn 2: đơn hàng, PO, thanh toán — chưa nằm trong file này)
-- =====================================================================

-- ---------- 0. NGƯỜI DÙNG ----------
CREATE TABLE users (
  id            BIGSERIAL PRIMARY KEY,
  full_name     VARCHAR(150) NOT NULL,
  email         VARCHAR(150) NOT NULL UNIQUE,
  role          VARCHAR(20)  NOT NULL DEFAULT 'STAFF'
                CHECK (role IN ('ADMIN','PURCHASING','SALES','STAFF')),
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- 1. DANH MỤC (MASTER DATA) ----------
CREATE TABLE ports (
  id            BIGSERIAL PRIMARY KEY,
  code          VARCHAR(10)  NOT NULL UNIQUE,          -- HCM, HP (mã nội bộ, khớp Excel)
  un_locode     VARCHAR(5),                            -- VNSGN, VNHPH
  name          VARCHAR(100) NOT NULL,                 -- HCM (Cát Lái)
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE fee_types (
  id               SMALLSERIAL PRIMARY KEY,
  code             VARCHAR(20)  NOT NULL UNIQUE,       -- LCC, LOGISTICS, SALES, OPS, BANK, DOC
  name             VARCHAR(100) NOT NULL,
  is_port_specific BOOLEAN NOT NULL DEFAULT FALSE,     -- TRUE: mức phí khác nhau theo cảng (LCC)
  sort_order       SMALLINT NOT NULL DEFAULT 0,
  is_active        BOOLEAN NOT NULL DEFAULT TRUE
);

-- Định mức phí có hiệu lực theo thời gian. port_id NULL = áp dụng cho mọi cảng.
CREATE TABLE fee_rates (
  id                  BIGSERIAL PRIMARY KEY,
  fee_type_id         SMALLINT NOT NULL REFERENCES fee_types(id),
  port_id             BIGINT REFERENCES ports(id),
  amount_vnd_per_ton  NUMERIC(14,2) NOT NULL CHECK (amount_vnd_per_ton >= 0),
  effective_from      DATE NOT NULL,
  effective_to        DATE,                            -- NULL = còn hiệu lực
  created_by          BIGINT REFERENCES users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_fee_rate UNIQUE NULLS NOT DISTINCT (fee_type_id, port_id, effective_from),
  CONSTRAINT ck_fee_rate_dates CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE TABLE suppliers (
  id             BIGSERIAL PRIMARY KEY,
  code           VARCHAR(20)  NOT NULL UNIQUE,
  name           VARCHAR(200) NOT NULL,
  country        VARCHAR(60),
  contact_name   VARCHAR(100),
  phone          VARCHAR(30),
  email          VARCHAR(150),
  payment_terms  VARCHAR(100),                         -- VD: TT 30% trước, 70% khi có B/L
  is_active      BOOLEAN NOT NULL DEFAULT TRUE,
  note           TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE products (
  id                     BIGSERIAL PRIMARY KEY,
  code                   VARCHAR(30)  NOT NULL UNIQUE,
  name                   VARCHAR(150) NOT NULL,        -- Hành lai
  spec                   VARCHAR(100),                 -- 25-32 (cỡ/quy cách); NULL nếu không có
  hs_code                VARCHAR(12),
  default_bag_weight_kg  NUMERIC(10,3),
  vat_rate               NUMERIC(5,4) NOT NULL DEFAULT 0.05 CHECK (vat_rate BETWEEN 0 AND 1),
  is_active              BOOLEAN NOT NULL DEFAULT TRUE,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_product_name_spec UNIQUE NULLS NOT DISTINCT (name, spec)
);

CREATE TABLE exchange_rates (
  id          BIGSERIAL PRIMARY KEY,
  rate_date   DATE NOT NULL,
  currency    CHAR(3) NOT NULL DEFAULT 'USD',
  rate_vnd    NUMERIC(12,2) NOT NULL CHECK (rate_vnd > 0),
  source      VARCHAR(30) NOT NULL DEFAULT 'VCB',
  CONSTRAINT uq_exchange_rate UNIQUE (rate_date, currency, source)
);

-- ---------- 2. KHÁCH HÀNG & YÊU CẦU BÁO GIÁ (bắt đầu quy trình) ----------
CREATE TABLE customers (
  id               BIGSERIAL PRIMARY KEY,
  code             VARCHAR(20)  NOT NULL UNIQUE,
  name             VARCHAR(200) NOT NULL,
  tax_code         VARCHAR(20),
  address          TEXT,
  contact_name     VARCHAR(100),
  phone            VARCHAR(30),
  email            VARCHAR(150),
  default_port_id  BIGINT REFERENCES ports(id),
  payment_terms    VARCHAR(100),
  is_active        BOOLEAN NOT NULL DEFAULT TRUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Yêu cầu báo giá của khách = ĐIỂM BẮT ĐẦU của quy trình
CREATE TABLE customer_requests (
  id             BIGSERIAL PRIMARY KEY,
  request_no     VARCHAR(30) NOT NULL UNIQUE,         -- YC-2026-0001
  customer_id    BIGINT NOT NULL REFERENCES customers(id),
  request_date   DATE NOT NULL,
  quote_deadline DATE,                                -- hạn phải gửi báo giá cho khách
  status         VARCHAR(12) NOT NULL DEFAULT 'NEW'
                 CHECK (status IN ('NEW','SOURCING','QUOTED','CANCELLED')),
  note           TEXT,
  created_by     BIGINT REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Mỗi dòng: mặt hàng + cảng đến + quy cách + số lượng khách cần
CREATE TABLE customer_request_items (
  id                         BIGSERIAL PRIMARY KEY,
  request_id                 BIGINT NOT NULL REFERENCES customer_requests(id) ON DELETE CASCADE,
  line_no                    SMALLINT NOT NULL,
  product_id                 BIGINT NOT NULL REFERENCES products(id),          -- mặt hàng (tên + cỡ)
  port_id                    BIGINT NOT NULL REFERENCES ports(id),             -- cảng đến
  bag_weight_kg              NUMERIC(10,3) NOT NULL CHECK (bag_weight_kg > 0), -- quy cách đóng bao
  quantity_kg                NUMERIC(14,3) NOT NULL CHECK (quantity_kg > 0),   -- số lượng khách cần
  required_delivery_date     DATE,
  selected_supplier_item_id  BIGINT,                  -- NCC được chọn (FK thêm sau khi tạo bảng NCC)
  note                       TEXT,
  CONSTRAINT uq_cr_item_line UNIQUE (request_id, line_no)
);

-- ---------- 3. BÁO GIÁ NHÀ CUNG CẤP (theo từng dòng yêu cầu) ----------
CREATE TABLE supplier_quotations (
  id             BIGSERIAL PRIMARY KEY,
  quote_no       VARCHAR(30) NOT NULL UNIQUE,          -- BGNCC-2026-0001
  supplier_id    BIGINT NOT NULL REFERENCES suppliers(id),
  quote_date     DATE   NOT NULL,
  valid_until    DATE,
  port_id        BIGINT NOT NULL REFERENCES ports(id), -- cảng đến
  currency       CHAR(3) NOT NULL DEFAULT 'USD',
  exchange_rate  NUMERIC(12,2) NOT NULL CHECK (exchange_rate BETWEEN 10000 AND 50000),
  status         VARCHAR(12) NOT NULL DEFAULT 'ACTIVE'
                 CHECK (status IN ('DRAFT','ACTIVE','SELECTED','REJECTED','EXPIRED','SUPERSEDED')),
  supersedes_id  BIGINT REFERENCES supplier_quotations(id), -- báo giá sửa lại của báo giá nào
  note           TEXT,
  created_by     BIGINT REFERENCES users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE supplier_quotation_items (
  id                        BIGSERIAL PRIMARY KEY,
  quotation_id              BIGINT NOT NULL REFERENCES supplier_quotations(id) ON DELETE CASCADE,
  line_no                   SMALLINT NOT NULL,
  request_item_id           BIGINT REFERENCES customer_request_items(id), -- báo cho dòng yêu cầu nào; NULL = báo giá tham khảo
  product_id                BIGINT NOT NULL REFERENCES products(id),
  bag_weight_kg             NUMERIC(10,3) NOT NULL CHECK (bag_weight_kg > 0),
  bag_count                 INTEGER       NOT NULL CHECK (bag_count > 0),       -- số bao NCC chào
  quantity_kg               NUMERIC(14,3) GENERATED ALWAYS AS (bag_weight_kg * bag_count) STORED,
  unit_price_usd_per_kg     NUMERIC(12,6) NOT NULL CHECK (unit_price_usd_per_kg > 0 AND unit_price_usd_per_kg <= 20),
  -- Các cột tính toán: backend (hoặc fn_recalc_supplier_item) ghi, frontend KHÔNG gửi lên
  cost_vnd_per_ton          NUMERIC(16,2),
  fees_total_vnd_per_ton    NUMERIC(16,2),
  landed_cost_vnd_per_ton   NUMERIC(16,2),
  vat_rate                  NUMERIC(5,4) NOT NULL DEFAULT 0.05,
  amount_before_vat         NUMERIC(18,0),
  vat_amount                NUMERIC(18,0),
  amount_after_vat          NUMERIC(18,0),
  note                      TEXT,
  CONSTRAINT uq_sq_item_line UNIQUE (quotation_id, line_no)
);

-- Ảnh chụp (snapshot) phí áp dụng cho từng dòng => đổi định mức sau này không làm sai báo giá cũ
CREATE TABLE supplier_quotation_item_fees (
  id                  BIGSERIAL PRIMARY KEY,
  item_id             BIGINT   NOT NULL REFERENCES supplier_quotation_items(id) ON DELETE CASCADE,
  fee_type_id         SMALLINT NOT NULL REFERENCES fee_types(id),
  amount_vnd_per_ton  NUMERIC(14,2) NOT NULL CHECK (amount_vnd_per_ton >= 0),
  CONSTRAINT uq_item_fee UNIQUE (item_id, fee_type_id)
);

ALTER TABLE customer_request_items
  ADD CONSTRAINT fk_cr_item_selected FOREIGN KEY (selected_supplier_item_id) REFERENCES supplier_quotation_items(id);

-- ---------- 4. CHỈ MỤC ----------
CREATE INDEX ix_sq_items_request ON supplier_quotation_items (request_item_id);
CREATE INDEX ix_cr_customer ON customer_requests (customer_id, request_date DESC);
CREATE INDEX ix_sq_supplier_date ON supplier_quotations (supplier_id, quote_date DESC);
CREATE INDEX ix_sq_items_product ON supplier_quotation_items (product_id);
CREATE INDEX ix_fee_rates_lookup ON fee_rates (fee_type_id, port_id, effective_from DESC);

-- ---------- 5. HÀM NGHIỆP VỤ ----------
-- 5.1 Định mức phí áp dụng cho 1 cảng tại 1 ngày (ưu tiên mức riêng của cảng, sau đó mức chung)
CREATE FUNCTION fn_fee_rates_for(p_port_id BIGINT, p_date DATE)
RETURNS TABLE (fee_type_id SMALLINT, fee_code VARCHAR, amount_vnd_per_ton NUMERIC)
LANGUAGE sql STABLE AS $$
  SELECT ft.id, ft.code, r.amount_vnd_per_ton
  FROM fee_types ft
  CROSS JOIN LATERAL (
    SELECT fr.amount_vnd_per_ton
    FROM fee_rates fr
    WHERE fr.fee_type_id = ft.id
      AND (fr.port_id = p_port_id OR fr.port_id IS NULL)
      AND fr.effective_from <= p_date
      AND (fr.effective_to IS NULL OR fr.effective_to >= p_date)
    ORDER BY (fr.port_id IS NULL), fr.effective_from DESC
    LIMIT 1
  ) r
  WHERE ft.is_active
  ORDER BY ft.sort_order;
$$;

-- 5.2 Tính lại 1 dòng báo giá NCC (công thức giống hệt HTML/Excel)
CREATE FUNCTION fn_recalc_supplier_item(p_item_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_rate NUMERIC; v_fees NUMERIC;
BEGIN
  SELECT q.exchange_rate INTO v_rate
  FROM supplier_quotation_items i JOIN supplier_quotations q ON q.id = i.quotation_id
  WHERE i.id = p_item_id;

  SELECT COALESCE(SUM(amount_vnd_per_ton), 0) INTO v_fees
  FROM supplier_quotation_item_fees WHERE item_id = p_item_id;

  UPDATE supplier_quotation_items i SET
    cost_vnd_per_ton        = i.unit_price_usd_per_kg * v_rate * 1000,
    fees_total_vnd_per_ton  = v_fees,
    landed_cost_vnd_per_ton = i.unit_price_usd_per_kg * v_rate * 1000 + v_fees,
    amount_before_vat       = ROUND((i.unit_price_usd_per_kg * v_rate * 1000 + v_fees) * i.quantity_kg / 1000),
    vat_amount              = ROUND(ROUND((i.unit_price_usd_per_kg * v_rate * 1000 + v_fees) * i.quantity_kg / 1000) * i.vat_rate),
    amount_after_vat        = ROUND((i.unit_price_usd_per_kg * v_rate * 1000 + v_fees) * i.quantity_kg / 1000)
                            + ROUND(ROUND((i.unit_price_usd_per_kg * v_rate * 1000 + v_fees) * i.quantity_kg / 1000) * i.vat_rate)
  WHERE i.id = p_item_id;
END $$;

-- 5.3 Chụp phí mặc định vào 1 dòng (gọi khi tạo dòng mới; người dùng có thể sửa sau)
CREATE FUNCTION fn_snapshot_default_fees(p_item_id BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_port BIGINT; v_date DATE;
BEGIN
  SELECT q.port_id, q.quote_date INTO v_port, v_date
  FROM supplier_quotation_items i JOIN supplier_quotations q ON q.id = i.quotation_id
  WHERE i.id = p_item_id;

  INSERT INTO supplier_quotation_item_fees (item_id, fee_type_id, amount_vnd_per_ton)
  SELECT p_item_id, f.fee_type_id, f.amount_vnd_per_ton FROM fn_fee_rates_for(v_port, v_date) f
  ON CONFLICT (item_id, fee_type_id) DO NOTHING;

  PERFORM fn_recalc_supplier_item(p_item_id);
END $$;

-- ---------- 6. VIEW SO SÁNH ----------
-- 7.1 SO SÁNH CHÍNH: theo từng dòng yêu cầu của khách, tính lại tổng tiền theo ĐÚNG SỐ LƯỢNG KHÁCH CẦN
--     => mọi NCC cùng số lượng, so tổng sau VAT là công bằng.
CREATE VIEW v_request_quote_comparison AS
WITH latest AS (
  SELECT DISTINCT ON (i.request_item_id, q.supplier_id, i.bag_weight_kg)
    ri.request_id, r.request_no, i.request_item_id, ri.line_no AS request_line_no,
    c.name AS customer_name,
    ri.product_id, TRIM(p.name || ' ' || COALESCE(p.spec, '')) AS product_name,
    ri.port_id, pt.code AS port_code,
    ri.bag_weight_kg AS requested_bag_weight_kg, ri.quantity_kg AS requested_quantity_kg,
    i.id AS supplier_item_id, q.id AS quotation_id, q.quote_no, q.quote_date,
    q.supplier_id, s.name AS supplier_name,
    i.bag_weight_kg AS offered_bag_weight_kg, i.quantity_kg AS offered_quantity_kg,
    i.unit_price_usd_per_kg, q.exchange_rate,
    i.cost_vnd_per_ton, i.fees_total_vnd_per_ton, i.landed_cost_vnd_per_ton, i.vat_rate,
    (i.bag_weight_kg = ri.bag_weight_kg) AS spec_match,             -- đúng quy cách bao
    (i.quantity_kg >= ri.quantity_kg)    AS quantity_enough,        -- NCC chào đủ số lượng
    (q.port_id = ri.port_id)             AS port_match,
    COALESCE(ri.selected_supplier_item_id = i.id, FALSE) AS is_selected
  FROM supplier_quotation_items i
  JOIN supplier_quotations q      ON q.id = i.quotation_id
  JOIN customer_request_items ri  ON ri.id = i.request_item_id
  JOIN customer_requests r        ON r.id = ri.request_id
  JOIN customers c                ON c.id = r.customer_id
  JOIN suppliers s                ON s.id = q.supplier_id
  JOIN products p                 ON p.id = ri.product_id
  JOIN ports pt                   ON pt.id = ri.port_id
  WHERE q.status IN ('ACTIVE','SELECTED')
    AND (q.valid_until IS NULL OR q.valid_until >= CURRENT_DATE)
  ORDER BY i.request_item_id, q.supplier_id, i.bag_weight_kg, q.quote_date DESC, q.id DESC, i.id DESC
), priced AS (
  SELECT l.*,
    (l.spec_match AND l.quantity_enough AND l.port_match) AS eligible,
    ROUND(l.landed_cost_vnd_per_ton * l.requested_quantity_kg / 1000) AS req_amount_before_vat,
    ROUND(ROUND(l.landed_cost_vnd_per_ton * l.requested_quantity_kg / 1000) * l.vat_rate) AS req_vat_amount
  FROM latest l
), totals AS (
  SELECT p.*, p.req_amount_before_vat + p.req_vat_amount AS req_amount_after_vat FROM priced p
)
SELECT t.*,
  RANK() OVER w AS price_rank,
  MIN(t.req_amount_after_vat) FILTER (WHERE t.eligible) OVER (PARTITION BY t.request_item_id) AS best_amount_after_vat,
  t.req_amount_after_vat
    - MIN(t.req_amount_after_vat) FILTER (WHERE t.eligible) OVER (PARTITION BY t.request_item_id) AS diff_amount,
  ROUND((t.req_amount_after_vat::numeric
    / NULLIF(MIN(t.req_amount_after_vat) FILTER (WHERE t.eligible) OVER (PARTITION BY t.request_item_id), 0) - 1) * 100, 2) AS diff_pct,
  (t.eligible AND RANK() OVER w = 1) AS is_best
FROM totals t
WINDOW w AS (PARTITION BY t.request_item_id ORDER BY (NOT t.eligible), t.req_amount_after_vat);

-- 7.2 BẢNG GIÁ THAM KHẢO theo tấn (mọi báo giá, kể cả không gắn yêu cầu)
-- Lấy báo giá MỚI NHẤT của mỗi NCC cho từng (sản phẩm, cảng, quy cách bao), xếp hạng TRONG CÙNG SẢN PHẨM.
CREATE VIEW v_supplier_quote_comparison AS
WITH latest AS (
  SELECT DISTINCT ON (q.supplier_id, i.product_id, q.port_id, i.bag_weight_kg)
    i.id AS item_id, q.id AS quotation_id, q.quote_no, q.quote_date, q.valid_until, q.status,
    q.supplier_id, s.name AS supplier_name,
    i.product_id, TRIM(p.name || ' ' || COALESCE(p.spec, '')) AS product_name,
    q.port_id, pt.code AS port_code, pt.name AS port_name,
    i.bag_weight_kg, i.bag_count, i.quantity_kg,
    i.unit_price_usd_per_kg, q.exchange_rate,
    i.cost_vnd_per_ton, i.fees_total_vnd_per_ton, i.landed_cost_vnd_per_ton,
    i.amount_before_vat, i.vat_amount, i.amount_after_vat
  FROM supplier_quotation_items i
  JOIN supplier_quotations q ON q.id = i.quotation_id
  JOIN suppliers s  ON s.id = q.supplier_id
  JOIN products  p  ON p.id = i.product_id
  JOIN ports     pt ON pt.id = q.port_id
  WHERE q.status IN ('ACTIVE','SELECTED')
    AND (q.valid_until IS NULL OR q.valid_until >= CURRENT_DATE)
  ORDER BY q.supplier_id, i.product_id, q.port_id, i.bag_weight_kg, q.quote_date DESC, q.id DESC, i.id DESC
)
SELECT l.*,
  RANK() OVER w AS price_rank,
  MIN(l.landed_cost_vnd_per_ton) OVER (PARTITION BY l.product_id) AS best_landed_cost_vnd_per_ton,
  ROUND((l.landed_cost_vnd_per_ton / MIN(l.landed_cost_vnd_per_ton) OVER (PARTITION BY l.product_id) - 1) * 100, 2) AS diff_pct,
  (RANK() OVER w = 1) AS is_best
FROM latest l
WINDOW w AS (PARTITION BY l.product_id ORDER BY l.landed_cost_vnd_per_ton);

-- 6.3 BÁO GIÁ GỬI KHÁCH: mỗi dòng yêu cầu + NCC đã chọn + giá theo số lượng khách cần
CREATE VIEW v_request_customer_quote AS
SELECT r.request_no, r.request_date, r.status AS request_status, c.name AS customer_name,
       ri.id AS request_item_id, ri.line_no,
       TRIM(p.name || ' ' || COALESCE(p.spec, '')) AS product_name,
       pt.code AS port_code, ri.bag_weight_kg, ri.quantity_kg,
       v.supplier_name, v.quote_no AS supplier_quote_no,
       v.landed_cost_vnd_per_ton AS price_vnd_per_ton,
       v.req_amount_before_vat AS amount_before_vat,
       v.req_vat_amount AS vat_amount,
       v.req_amount_after_vat AS amount_after_vat
FROM customer_request_items ri
JOIN customer_requests r ON r.id = ri.request_id
JOIN customers c ON c.id = r.customer_id
JOIN products p ON p.id = ri.product_id
JOIN ports pt ON pt.id = ri.port_id
LEFT JOIN v_request_quote_comparison v
       ON v.request_item_id = ri.id AND v.supplier_item_id = ri.selected_supplier_item_id;
