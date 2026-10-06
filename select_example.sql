-- VÍ DỤ: chọn NCC tối ưu cho yêu cầu YC-2026-0001 rồi xem báo giá gửi khách

-- B1. Mỗi dòng yêu cầu chọn NCC có is_best = TRUE (người dùng có thể chọn NCC khác)
UPDATE customer_request_items ri SET selected_supplier_item_id = v.supplier_item_id
FROM v_request_quote_comparison v
WHERE v.request_item_id = ri.id AND v.is_best AND v.request_no = 'YC-2026-0001';

-- B2. Đánh dấu báo giá NCC được chọn
UPDATE supplier_quotations q SET status = 'SELECTED', updated_at = now()
FROM supplier_quotation_items i
JOIN customer_request_items ri ON ri.selected_supplier_item_id = i.id
WHERE i.quotation_id = q.id;

-- B3. Đã gửi báo giá cho khách
UPDATE customer_requests SET status = 'QUOTED', updated_at = now() WHERE request_no = 'YC-2026-0001';

-- B4. Nội dung gửi khách
SELECT line_no, product_name, port_code, bag_weight_kg, quantity_kg, supplier_name,
       price_vnd_per_ton, amount_before_vat, vat_amount, amount_after_vat
FROM v_request_customer_quote WHERE request_no = 'YC-2026-0001' ORDER BY line_no;
