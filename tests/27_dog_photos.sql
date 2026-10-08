-- A photo of the dog.
--
-- Four things are proven:
--   1. A photo is kept in its three sizes, as the dog's profile photo.
--   2. A new photo replaces it, and the old files are handed back to delete.
--   3. Removing it hands its files back, and the dog has no photo.
--   4. A photo is kept in all three sizes or not at all.

BEGIN;
SET search_path = groom, public;
SELECT plan(6);

CREATE TEMP TABLE t_dog AS
SELECT add_dog(add_client('Mia', 'Lund', '410-555-0960', NULL, '00000000-0000-0000-0000-00000000b002'),
               'Ziggy', NULL, 'curly', 'male', NULL, '00000000-0000-0000-0000-00000000b002') AS id;

CREATE FUNCTION pg_temp.sizes(p_name text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(
    jsonb_build_object('rendition', 'original', 'object_key', 'private/dogs/' || p_name || '-o.jpg', 'width', 2000, 'height', 1500),
    jsonb_build_object('rendition', 'display',  'object_key', 'private/dogs/' || p_name || '-d.jpg', 'width', 1200, 'height', 900),
    jsonb_build_object('rendition', 'thumb',    'object_key', 'private/dogs/' || p_name || '-t.jpg', 'width', 256, 'height', 256)) $$;

-- --- 1. Kept in three sizes -------------------------------------------------------------------------
SELECT is(set_dog_photo((SELECT id FROM t_dog), pg_temp.sizes('a'), '00000000-0000-0000-0000-00000000b002'),
  '{}'::text[], 'The first photo replaces nothing');
SELECT results_eq(
  $$ SELECT rendition::text, exif_stripped FROM dog_photo WHERE dog_id = (SELECT id FROM t_dog) ORDER BY rendition::text $$,
  $$ VALUES ('display'::text, true), ('original', true), ('thumb', true) $$,
  'It is kept in three sizes, with the camera details stripped');

-- --- 2. Replaced -------------------------------------------------------------------------------------
SELECT is(
  (SELECT array_agg(k ORDER BY k) FROM unnest(set_dog_photo((SELECT id FROM t_dog), pg_temp.sizes('b'),
                                                            '00000000-0000-0000-0000-00000000b002')) k),
  ARRAY['private/dogs/a-d.jpg', 'private/dogs/a-o.jpg', 'private/dogs/a-t.jpg'],
  'A new photo hands back the old one''s files to delete');

-- --- 3. Removed --------------------------------------------------------------------------------------
SELECT is(cardinality(remove_dog_photo((SELECT id FROM t_dog), '00000000-0000-0000-0000-00000000b002')), 3,
  'Removing it hands back its three files');
SELECT is_empty($$ SELECT 1 FROM dog_photo WHERE dog_id = (SELECT id FROM t_dog) $$, 'And the dog has no photo');

-- --- 4. All or nothing -------------------------------------------------------------------------------
SELECT throws_ok(
  $$ SELECT set_dog_photo((SELECT id FROM t_dog), pg_temp.sizes('c') - 2, '00000000-0000-0000-0000-00000000b002') $$,
  '23514', NULL, 'A photo missing one of its sizes is refused');

SELECT * FROM finish();
ROLLBACK;
