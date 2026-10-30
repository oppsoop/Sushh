alter table reports drop constraint if exists reports_target_type_check;
alter table reports add constraint reports_target_type_check
  check (target_type in ('user', 'post', 'comment', 'message', 'story', 'media'));
