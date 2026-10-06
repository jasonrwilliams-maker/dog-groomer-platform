-- =============================================================================
-- 23. Breeds — the list the check-in screen picks from
--
-- Source: the breed index on Chewy's dog-breed pages, as the shop supplied it
-- on 2026-10-06. The coat beside each name is the coat that breed usually has;
-- it only fills in the coat on a new dog's form, and the groomer can change it.
-- The dog's own coat is what drives the work (dog.coat_type_id), because the
-- label lies.
--
-- "Mixed" marks a breed that is itself a cross (a Cavapoo, a Goldendoodle).
-- A dog that is a mix of two breeds is recorded on the dog instead: its main
-- breed, dog.is_mixed, and the other breed if the owner knows it.
--
-- This is the one file to edit to change the list. It can be run again on a
-- database that already has it: a name already there gets this file's coat
-- and mixed flag, and nothing is removed — a breed some dog already has stays.
-- =============================================================================

SET search_path = groom, public;

CREATE TEMP TABLE breed_seed (name text, coat text, mixed boolean);
INSERT INTO breed_seed (name, coat, mixed) VALUES
  -- A
  ('Affenpinscher', 'wiry', false),
  ('Afghan Hound', 'silky', false),
  ('Airedale Terrier', 'wiry', false),
  ('Akita', 'double', false),
  ('Alaskan Klee Kai', 'double', false),
  ('Alaskan Malamute', 'double', false),
  ('American Bulldog', 'smooth', false),
  ('American Eskimo Dog', 'double', false),
  ('American Foxhound', 'smooth', false),
  ('American Pit Bull Terrier', 'smooth', false),
  ('American Staffordshire Terrier', 'smooth', false),
  ('Anatolian Shepherd', 'double', false),
  ('Aussiedoodle', 'curly', true),
  ('Australian Cattle Dog', 'double', false),
  ('Australian Kelpie', 'double', false),
  ('Australian Shepherd', 'double', false),
  ('Australian Terrier', 'wiry', false),
  -- B
  ('Barbet', 'curly', false),
  ('Basenji', 'smooth', false),
  ('Basset Fauve de Bretagne', 'wiry', false),
  ('Basset Hound', 'smooth', false),
  ('Beagle', 'smooth', false),
  ('Bearded Collie', 'double', false),
  ('Beauceron', 'double', false),
  ('Bedlington Terrier', 'curly', false),
  ('Belgian Malinois', 'double', false),
  ('Belgian Sheepdog (Groenendael)', 'double', false),
  ('Belgian Tervuren', 'double', false),
  ('Bernedoodle', 'curly', true),
  ('Bernese Mountain Dog', 'double', false),
  ('Bichon Frise', 'curly', false),
  ('Biewer Terrier', 'silky', false),
  ('Black and Tan Coonhound', 'smooth', false),
  ('Black Russian Terrier', 'wiry', false),
  ('Bloodhound', 'smooth', false),
  ('Bluetick Coonhound', 'smooth', false),
  ('Boerboel', 'smooth', false),
  ('Bolognese', 'curly', false),
  ('Border Collie', 'double', false),
  ('Border Terrier', 'wiry', false),
  ('Borzoi', 'silky', false),
  ('Boston Terrier', 'smooth', false),
  ('Bouvier des Flandres', 'wiry', false),
  ('Boxer', 'smooth', false),
  ('Boykin Spaniel', 'silky', false),
  ('Briard', 'double', false),
  ('Brittany', 'silky', false),
  ('Brussels Griffon', 'wiry', false),
  ('Bull Terrier', 'smooth', false),
  ('Bulldog (English Bulldog)', 'smooth', false),
  ('Bullmastiff', 'smooth', false),
  -- C
  ('Cairn Terrier', 'wiry', false),
  ('Cane Corso', 'smooth', false),
  ('Cardigan Welsh Corgi', 'double', false),
  ('Carolina Dog', 'smooth', false),
  ('Catahoula Leopard Dog', 'smooth', false),
  ('Cavalier King Charles Spaniel', 'silky', false),
  ('Cavapoo', 'curly', true),
  ('Chesapeake Bay Retriever', 'double', false),
  ('Chihuahua', 'smooth', false),
  ('Chinese Crested', 'silky', false),
  ('Chinese Shar-Pei', 'smooth', false),
  ('Chinook', 'double', false),
  ('Chiweenie', 'smooth', true),
  ('Chorkie', 'silky', true),
  ('Chow Chow', 'double', false),
  ('Chug Dog', 'smooth', true),
  ('Clumber Spaniel', 'silky', false),
  ('Cockapoo', 'curly', true),
  ('Cocker Spaniel', 'silky', false),
  ('Collie', 'double', false),
  ('Coton de Tulear', 'silky', false),
  -- D
  ('Dachshund', 'smooth', false),
  ('Dalmatian', 'smooth', false),
  ('Doberman Pinscher', 'smooth', false),
  ('Dogo Argentino', 'smooth', false),
  ('Dogue de Bordeaux', 'smooth', false),
  ('Dutch Shepherd', 'double', false),
  -- E
  ('English Cocker Spaniel', 'silky', false),
  ('English Setter', 'silky', false),
  ('English Springer Spaniel', 'silky', false),
  ('Entlebucher Mountain Dog', 'double', false),
  -- F
  ('Flat-Coated Retriever', 'silky', false),
  ('French Bulldog', 'smooth', false),
  ('Frenchton', 'smooth', true),
  -- G
  ('German Pinscher', 'smooth', false),
  ('German Shepherd', 'double', false),
  ('German Shorthaired Pointer', 'smooth', false),
  ('German Spitz', 'double', false),
  ('German Wirehaired Pointer', 'wiry', false),
  ('Giant Schnauzer', 'wiry', false),
  ('Golden Retriever', 'double', false),
  ('Goldendoodle', 'curly', true),
  ('Gordon Setter', 'silky', false),
  ('Great Dane', 'smooth', false),
  ('Great Pyrenees', 'double', false),
  ('Greater Swiss Mountain Dog', 'double', false),
  ('Greyhound', 'smooth', false),
  -- H
  ('Harrier', 'smooth', false),
  ('Havanese', 'silky', false),
  -- I
  ('Irish Setter', 'silky', false),
  ('Irish Terrier', 'wiry', false),
  ('Irish Water Spaniel', 'curly', false),
  ('Irish Wolfhound', 'wiry', false),
  ('Italian Greyhound', 'smooth', false),
  -- J
  ('Jack Russell Terrier', 'smooth', false),
  ('Japanese Chin', 'silky', false),
  -- K
  ('Keeshond', 'double', false),
  ('Kerry Blue Terrier', 'curly', false),
  ('Komondor', 'curly', false),
  ('Korean Jindo Dog', 'double', false),
  ('Kuvasz', 'double', false),
  -- L
  ('Labradoodle', 'curly', true),
  ('Labrador Retriever', 'double', false),
  ('Lagotto Romagnolo', 'curly', false),
  ('Lakeland Terrier', 'wiry', false),
  ('Lancashire Heeler', 'smooth', false),
  ('Leonberger', 'double', false),
  ('Lhasa Apso', 'silky', false),
  -- M
  ('Maltese', 'silky', false),
  ('Maltipoo', 'curly', true),
  ('Manchester Terrier', 'smooth', false),
  ('Mastiff', 'smooth', false),
  ('Miniature American Shepherd', 'double', false),
  ('Miniature Pinscher', 'smooth', false),
  ('Miniature Poodle', 'curly', false),
  ('Miniature Schnauzer', 'wiry', false),
  ('Morkie', 'silky', true),
  -- N
  ('Neapolitan Mastiff', 'smooth', false),
  ('Nederlandse Kooikerhondje', 'silky', false),
  ('Newfoundland', 'double', false),
  ('Norfolk Terrier', 'wiry', false),
  ('Norwegian Elkhound', 'double', false),
  ('Norwich Terrier', 'wiry', false),
  ('Nova Scotia Duck Tolling Retriever', 'double', false),
  -- O
  ('Old English Sheepdog', 'double', false),
  -- P
  ('Papillon', 'silky', false),
  ('Patterdale Terrier', 'smooth', false),
  ('Pekingese', 'double', false),
  ('Pembroke Welsh Corgi', 'double', false),
  ('Pharaoh Hound', 'smooth', false),
  ('Plott Hound', 'smooth', false),
  ('Pointer', 'smooth', false),
  ('Pomchi', 'double', true),
  ('Pomeranian', 'double', false),
  ('Pomsky', 'double', true),
  ('Portuguese Water Dog', 'curly', false),
  ('Pudelpointer', 'wiry', false),
  ('Pug', 'smooth', false),
  ('Puggle', 'smooth', true),
  ('Puli', 'curly', false),
  ('Pumi', 'curly', false),
  -- R
  ('Rat Terrier', 'smooth', false),
  ('Redbone Coonhound', 'smooth', false),
  ('Rhodesian Ridgeback', 'smooth', false),
  ('Rottweiler', 'smooth', false),
  ('Russell Terrier', 'smooth', false),
  ('Russian Tsvetnaya Bolonka', 'curly', false),
  -- S
  ('Saint Bernard', 'double', false),
  ('Saluki', 'silky', false),
  ('Samoyed', 'double', false),
  ('Schipperke', 'double', false),
  ('Schnoodle', 'curly', true),
  ('Scottish Deerhound', 'wiry', false),
  ('Scottish Terrier', 'wiry', false),
  ('Sealyham Terrier', 'wiry', false),
  ('Sheepadoodle', 'curly', true),
  ('Shetland Sheepdog', 'double', false),
  ('Shiba Inu', 'double', false),
  ('Shih Tzu', 'silky', false),
  ('Siberian Husky', 'double', false),
  ('Silken Windhound', 'silky', false),
  ('Silky Terrier', 'silky', false),
  ('Smooth Fox Terrier', 'smooth', false),
  ('Soft Coated Wheaten Terrier', 'silky', false),
  ('Spanish Water Dog', 'curly', false),
  ('Staffordshire Bull Terrier', 'smooth', false),
  ('Standard Poodle', 'curly', false),
  ('Standard Schnauzer', 'wiry', false),
  ('Swedish Vallhund', 'double', false),
  -- T
  ('Teddy Roosevelt Terrier', 'smooth', false),
  ('Thai Ridgeback', 'smooth', false),
  ('Tibetan Mastiff', 'double', false),
  ('Tibetan Spaniel', 'silky', false),
  ('Tibetan Terrier', 'double', false),
  ('Toy Fox Terrier', 'smooth', false),
  ('Toy Poodle', 'curly', false),
  ('Treeing Walker Coonhound', 'smooth', false),
  -- V
  ('Vizsla', 'smooth', false),
  -- W
  ('Weimaraner', 'smooth', false),
  ('Welsh Springer Spaniel', 'silky', false),
  ('Welsh Terrier', 'wiry', false),
  ('West Highland White Terrier', 'wiry', false),
  ('Whippet', 'smooth', false),
  ('Wire Fox Terrier', 'wiry', false),
  ('Wirehaired Pointing Griffon', 'wiry', false),
  -- X
  ('Xoloitzcuintli', 'smooth', false),
  -- Y
  ('Yorkiepoo', 'silky', true),
  ('Yorkshire Terrier', 'silky', false);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM breed_seed s LEFT JOIN coat_type ct ON ct.code = s.coat WHERE ct.id IS NULL) THEN
        RAISE EXCEPTION 'A breed in sql/23_breed_seed.sql names a coat that does not exist';
    END IF;
END $$;

-- Only what differs is written, so a re-run with no edits changes nothing.
INSERT INTO breed (name, default_coat_type_id, is_mixed)
SELECT s.name, ct.id, s.mixed
  FROM breed_seed s JOIN coat_type ct ON ct.code = s.coat
ON CONFLICT (name) DO UPDATE
   SET default_coat_type_id = EXCLUDED.default_coat_type_id, is_mixed = EXCLUDED.is_mixed
 WHERE (breed.default_coat_type_id, breed.is_mixed) IS DISTINCT FROM
       (EXCLUDED.default_coat_type_id, EXCLUDED.is_mixed);

DROP TABLE breed_seed;
