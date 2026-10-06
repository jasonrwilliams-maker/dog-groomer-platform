-- =============================================================================
-- 25. Allergens — the list the check-in screen picks from
--
-- Grouped by what each changes for the groomer (allergen.allergy_type):
--
--   contact        don't put it on the dog. The products and ingredients a
--                  shop actually uses, so "category" says which kind.
--   flea           flea allergy dermatitis: one flea bite is enough
--   environmental  atopy: pollens, mites, moulds. Itchy face, ears, paws,
--                  armpits and belly, often worse with the seasons
--   food           the proteins and grains in treats
--
-- The four groups follow the overview of dog skin allergies the shop supplied
-- on 2026-10-06. The names are a starting list; groomers add to it from the
-- screen, saying which group a new one belongs to.
--
-- This is the one file to edit to change the list. It can be run again: a
-- name already there gets this file's group and category, and nothing is
-- removed — an allergen some dog already has stays.
-- =============================================================================

SET search_path = groom, public;

CREATE TEMP TABLE allergen_seed (name text, allergy_type text, category text);
INSERT INTO allergen_seed (name, allergy_type, category) VALUES
  -- Contact: shampoos and what is in them
  ('Chlorhexidine shampoo',          'contact', 'shampoo'),
  ('Oatmeal shampoo',                'contact', 'shampoo'),
  ('Medicated shampoo (benzoyl peroxide)', 'contact', 'shampoo'),
  ('Coal tar shampoo',               'contact', 'shampoo'),
  ('Flea and tick shampoo (pyrethrins)', 'contact', 'shampoo'),
  ('Sulfates (SLS)',                 'contact', 'shampoo'),
  ('Parabens',                       'contact', 'shampoo'),
  ('Propylene glycol',               'contact', 'shampoo'),
  -- Contact: conditioners, oils and topicals
  ('Coconut oil',                    'contact', 'conditioner'),
  ('Lanolin',                        'contact', 'conditioner'),
  ('Aloe vera',                      'contact', 'topical'),
  ('Tea tree oil',                   'contact', 'topical'),
  ('Lavender oil',                   'contact', 'topical'),
  ('Eucalyptus oil',                 'contact', 'topical'),
  ('Peppermint oil',                 'contact', 'topical'),
  ('Citrus oils',                    'contact', 'topical'),
  ('Ear cleaner',                    'contact', 'topical'),
  ('Styptic powder',                 'contact', 'topical'),
  -- Contact: scents and finishing
  ('Added fragrance',                'contact', 'fragrance'),
  ('Cologne / finishing spray',      'contact', 'fragrance'),
  ('Dyes and coloring',              'contact', 'other'),
  -- Contact: what the groomer touches the dog with
  ('Latex gloves',                   'contact', 'other'),
  ('Rubber (mats, brushes)',         'contact', 'other'),
  ('Nylon (leads, collars)',         'contact', 'other'),
  ('Wool',                           'contact', 'other'),
  -- Flea
  ('Flea bites (flea allergy dermatitis)', 'flea', 'other'),
  -- Environmental
  ('Tree pollen',                    'environmental', 'other'),
  ('Grass pollen',                   'environmental', 'other'),
  ('Weed pollen (ragweed)',          'environmental', 'other'),
  ('Dust mites',                     'environmental', 'other'),
  ('Mold spores',                    'environmental', 'other'),
  ('Feathers',                       'environmental', 'other'),
  ('Cat dander',                     'environmental', 'other'),
  -- Food: what treats are made of
  ('Chicken',                        'food', 'other'),
  ('Beef',                           'food', 'other'),
  ('Pork',                           'food', 'other'),
  ('Lamb',                           'food', 'other'),
  ('Turkey',                         'food', 'other'),
  ('Fish',                           'food', 'other'),
  ('Dairy',                          'food', 'other'),
  ('Egg',                            'food', 'other'),
  ('Wheat',                          'food', 'other'),
  ('Corn',                           'food', 'other'),
  ('Soy',                            'food', 'other'),
  ('Peanut butter',                  'food', 'other');

-- Only what differs is written, so a re-run with no edits changes nothing.
INSERT INTO allergen (name, allergy_type, category)
SELECT name, allergy_type, category FROM allergen_seed
ON CONFLICT (name) DO UPDATE
   SET allergy_type = EXCLUDED.allergy_type, category = EXCLUDED.category
 WHERE (allergen.allergy_type, allergen.category) IS DISTINCT FROM (EXCLUDED.allergy_type, EXCLUDED.category);

DROP TABLE allergen_seed;
