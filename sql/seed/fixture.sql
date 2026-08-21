-- =============================================================================
-- fixture.sql — the smallest shop that can exercise every rule.
--
-- Loaded ONCE into the test database, outside any test transaction. Every test
-- file wraps itself in BEGIN/ROLLBACK, so tests can add to this and never
-- damage it.
--
-- Fixed UUIDs so tests can reference rows by name instead of subquerying.
-- =============================================================================

SET search_path = groom, public;

INSERT INTO owner (id, first_name, last_name, email, phone) VALUES
  ('00000000-0000-0000-0000-00000000a001', 'Jason', 'Williams',
   'jason@example.test', '410-555-0100'),
  -- Opted out of email: exercises GR005.
  ('00000000-0000-0000-0000-00000000a002', 'Dana', 'Okoye',
   'dana@example.test', '410-555-0101');

UPDATE owner SET email_opted_out = true
 WHERE id = '00000000-0000-0000-0000-00000000a002';

INSERT INTO groomer (id, display_name, email, role) VALUES
  ('00000000-0000-0000-0000-00000000b001', 'Riane', 'riane@example.test', 'manager'),
  ('00000000-0000-0000-0000-00000000b002', 'Tanya', 'tanya@example.test', 'groomer');

INSERT INTO breed (id, name, default_coat_type_id) VALUES
  ('00000000-0000-0000-0000-00000000c001', 'Shih Tzu',
   (SELECT id FROM coat_type WHERE code = 'silky'));

INSERT INTO dog (id, owner_id, name, breed_id, coat_type_id, sex) VALUES
  ('00000000-0000-0000-0000-00000000d001', '00000000-0000-0000-0000-00000000a001',
   'Jaddi', '00000000-0000-0000-0000-00000000c001',
   (SELECT id FROM coat_type WHERE code = 'silky'), 'female'),
  ('00000000-0000-0000-0000-00000000d002', '00000000-0000-0000-0000-00000000a001',
   'Luna',  '00000000-0000-0000-0000-00000000c001',
   (SELECT id FROM coat_type WHERE code = 'silky'), 'female'),
  ('00000000-0000-0000-0000-00000000d003', '00000000-0000-0000-0000-00000000a002',
   'Biscuit', NULL,
   (SELECT id FROM coat_type WHERE code = 'curly'), 'male');
