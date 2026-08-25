-- =============================================================================
-- Call the file number what it is: mrn.
--
-- WHAT WAS WRONG
-- The column was named external_patient_id, and the word "external" was doing
-- real damage. It reads as "an identifier belonging to some other system" —
-- which is exactly what it is NOT. The MRN is the hospital's own permanent file
-- number for the patient, minted here from his.mrn_seq (see 004). Nothing
-- outside the HIS issues it.
--
-- The confusion is not hypothetical. It is the identifier the hospital files
-- results under, so a developer reading `externalPatientId` on a returned
-- result could reasonably conclude it came back from OpenELIS and should be
-- treated as foreign, unverified data. It is the opposite: it is ours, and it
-- never leaves and re-enters the HIS at all.
--
-- THE MODEL THIS MAKES EXPLICIT
-- A patient has TWO permanent identifiers, and they do different jobs:
--
--   patient_id  uuid, auto-generated, the primary key. Internal. What foreign
--               keys point at. Never shown to a clinician.
--   mrn         the file number. Generated, human-readable, permanent. What
--               staff quote, what a folder is labelled with, and what a result
--               is filed under.
--
-- Neither is derived from the other and neither ever changes.
--
-- WHY A RENAME AND NOT A NEW COLUMN
-- The values are correct and in use; only the name was wrong. Adding a second
-- column would leave two answers to "what is this patient's file number" and
-- guarantee they diverge.
-- =============================================================================

SET search_path TO his;

ALTER TABLE his.patients RENAME COLUMN external_patient_id TO mrn;

-- The unique constraint keeps its generated name through a column rename, which
-- would leave `patients_external_patient_id_key` enforcing a column that no
-- longer exists by that name. Rename it too, so an error message names
-- something a reader can find.
ALTER TABLE his.patients
    RENAME CONSTRAINT patients_external_patient_id_key TO patients_mrn_key;

COMMENT ON COLUMN his.patients.mrn IS
    'The patient file number: permanent, generated from his.mrn_seq, and the '
    'identifier results are filed under. Distinct from patient_id, which is the '
    'auto-generated internal primary key.';
