-- =====================================================================
-- DỮ LIỆU MẪU
-- =====================================================================
INSERT INTO users (full_name, email, role) VALUES ('Quản trị', 'admin@example.com', 'ADMIN');

INSERT INTO ports (code, un_locode, name) VALUES
  ('HCM', 'VNSGN', 'HCM (Cát Lái)'),
  ('HP',  'VNHPH', 'Hải Phòng');

INSERT INTO fee_types (code, name, is_port_specific, sort_order) VALUES
  ('LCC',       'Phí LCC (theo cảng)',      TRUE,  1),
  ('LOGISTICS', 'Chi phí logistics',        FALSE, 2),
  ('SALES',     'Chi phí bán hàng',         FALSE, 3),
  ('OPS',       'Chi phí Ops',              FALSE, 4),
  ('BANK',      'Phí chuyển tiền',          FALSE, 5),
  ('DOC',       'Phí chứng từ - hải quan',  FALSE, 6);

INSERT INTO fee_rates (fee_type_id, port_id, amount_vnd_per_ton, effective_from)
SELECT ft.id, p.id, v.amount, DATE '2026-01-01'
FROM (VALUES ('LCC','HCM',500000), ('LCC','HP',700000),
             ('LOGISTICS',NULL,600000), ('SALES',NULL,200000), ('OPS',NULL,15000),
             ('BANK',NULL,1000), ('DOC',NULL,56000)) v(fee, port, amount)
JOIN fee_types ft ON ft.code = v.fee
LEFT JOIN ports p ON p.code = v.port;

INSERT INTO suppliers (code, name, country) VALUES
  ('THIENTAN', 'Thiên Tân',   'Trung Quốc'),
  ('AKP',      'AKP',         'Ấn Độ'),
  ('SIVARAM',  'Sivaram SHT', 'Ấn Độ'),
  ('REDIMPEX', 'Red Impex',   'Ấn Độ');

INSERT INTO products (code, name, spec, default_bag_weight_kg, vat_rate) VALUES
  ('HL-2532',    'Hành lai',         '25-32',       10,  0.05),
  ('HL-3550',    'Hành lai',         '35-50',       10,  0.05),
  ('CAROT',      'Cà rốt',           NULL,          10,  0.05),
  ('S17-BEST',   'S17 Stem',         'best',        9.5, 0.05),
  ('S17-MED',    'S17 Stem',         'medium best', 9.5, 0.05),
  ('HANH-BELL',  'Hành Bellary',     NULL,          10,  0.05);

-- Header báo giá NCC
INSERT INTO supplier_quotations (quote_no, supplier_id, quote_date, port_id, exchange_rate, status, note)
SELECT v.no, s.id, v.d::date, p.id, v.rate, v.status, v.note
FROM (VALUES
  ('BGNCC-2026-0001','THIENTAN','2026-09-09','HCM',26170,'ACTIVE',NULL),
  ('BGNCC-2026-0002','THIENTAN','2026-09-08','HCM',26200,'SUPERSEDED','Cà rốt giá 0.238 — bị thay bằng 0002B'),
  ('BGNCC-2026-0003','THIENTAN','2026-09-08','HCM',26200,'ACTIVE','Báo lại cà rốt cùng ngày: 0.26438 (cần xác nhận)'),
  ('BGNCC-2026-0004','AKP',     '2026-09-13','HP', 26210,'ACTIVE','Excel ghi 2450 USD/tấn -> 2.45 USD/kg'),
  ('BGNCC-2026-0005','SIVARAM', '2026-09-13','HP', 26180,'ACTIVE','Excel ghi 2350 USD/tấn -> 2.35 USD/kg'),
  ('BGNCC-2026-0006','SIVARAM', '2026-09-16','HP', 26180,'ACTIVE',NULL),
  ('BGNCC-2026-0007','REDIMPEX','2026-09-16','HCM',26180,'ACTIVE',NULL)
) v(no, sup, d, port, rate, status, note)
JOIN suppliers s ON s.code = v.sup
JOIN ports p ON p.code = v.port;

UPDATE supplier_quotations SET supersedes_id = (SELECT id FROM supplier_quotations WHERE quote_no='BGNCC-2026-0002')
WHERE quote_no = 'BGNCC-2026-0003';

-- Dòng báo giá
INSERT INTO supplier_quotation_items (quotation_id, line_no, product_id, bag_weight_kg, bag_count, unit_price_usd_per_kg, vat_rate)
SELECT q.id, v.line, p.id, v.bag_kg, v.bags, v.price, p.vat_rate
FROM (VALUES
  ('BGNCC-2026-0001',1,'HL-2532',  10,  6000, 0.3648),
  ('BGNCC-2026-0001',2,'HL-3550',  10,  3000, 0.509),
  ('BGNCC-2026-0001',3,'HL-2532',  30,  1000, 0.3576),
  ('BGNCC-2026-0001',4,'HL-3550',  30,  1000, 0.501),
  ('BGNCC-2026-0002',1,'CAROT',    10,  2950, 0.238),
  ('BGNCC-2026-0003',1,'CAROT',    10,  2950, 0.26438),
  ('BGNCC-2026-0004',1,'S17-BEST', 9.5, 1400, 2.45),
  ('BGNCC-2026-0005',1,'S17-MED',  9.5, 1400, 2.35),
  ('BGNCC-2026-0006',1,'S17-BEST', 9.5, 1400, 2.525),
  ('BGNCC-2026-0006',2,'S17-MED',  9.5, 1400, 2.425),
  ('BGNCC-2026-0007',1,'HANH-BELL',10,  3000, 0.585)
) v(no, line, prod, bag_kg, bags, price)
JOIN supplier_quotations q ON q.quote_no = v.no
JOIN products p ON p.code = v.prod;

-- Khách hàng & yêu cầu báo giá (VÍ DỤ — file Excel chưa có thông tin khách)
INSERT INTO customers (code, name, default_port_id) SELECT 'KH001', 'Khách hàng mẫu A', id FROM ports WHERE code='HCM';

INSERT INTO customer_requests (request_no, customer_id, request_date, quote_deadline, status, note)
SELECT 'YC-2026-0001', id, DATE '2026-09-07', DATE '2026-09-17', 'SOURCING', 'Ví dụ minh họa' FROM customers WHERE code='KH001';

INSERT INTO customer_request_items (request_id, line_no, product_id, port_id, bag_weight_kg, quantity_kg)
SELECT r.id, v.line, p.id, pt.id, v.bag_kg, v.qty
FROM (VALUES (1,'HL-2532','HCM',10,60000), (2,'S17-BEST','HP',9.5,13300)) v(line, prod, port, bag_kg, qty)
JOIN customer_requests r ON r.request_no='YC-2026-0001'
JOIN products p ON p.code=v.prod JOIN ports pt ON pt.code=v.port;

-- Gắn báo giá NCC vào dòng yêu cầu
-- Dòng 1 (Hành lai 25-32, HCM, bao 10kg, 60 tấn): Thiên Tân chào 2 quy cách (bao 10kg và bao 30kg)
UPDATE supplier_quotation_items i SET request_item_id = ri.id
FROM supplier_quotations q, customer_request_items ri, customer_requests r
WHERE q.id = i.quotation_id AND r.id = ri.request_id AND r.request_no = 'YC-2026-0001'
  AND ((ri.line_no = 1 AND q.quote_no = 'BGNCC-2026-0001' AND i.line_no IN (1,3))
    OR (ri.line_no = 2 AND q.quote_no IN ('BGNCC-2026-0004','BGNCC-2026-0006') AND i.product_id = ri.product_id));

-- Chụp phí & tính toán cho mọi dòng
SELECT fn_snapshot_default_fees(id) FROM supplier_quotation_items ORDER BY id;
