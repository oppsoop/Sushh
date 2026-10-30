-- Denormalised receipt timestamps on messages so the sender can render
-- "sent / delivered / read" without joining the receipts table.
alter table messages add column if not exists delivered_at timestamptz;
alter table messages add column if not exists read_at timestamptz;
create index if not exists messages_delivered_idx on messages (conversation_id, delivered_at);
