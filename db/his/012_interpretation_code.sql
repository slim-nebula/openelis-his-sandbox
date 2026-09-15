-- =============================================================================
-- The HL7 code behind the interpretation label.
--
-- WHY A SECOND COLUMN AND NOT JUST THE LABEL
-- `interpretation` holds what the laboratory calls it — "Normal", "High",
-- "Critical high". That is the right thing to SHOW, and the wrong thing to make
-- a decision on. A screen that paints a result red by matching the word
-- "critical" stops painting it red the day a laboratory reconfigures its display
-- text to "Panic high", and nothing fails: the value still appears, still looks
-- ordinary, and the one signal that was supposed to be impossible to miss is
-- silently gone.
--
-- The code is stable where the label is not. HL7 v3 ObservationInterpretation
-- distinguishes the ordinary abnormal from the critical explicitly:
--
--     N          normal
--     A, H, L    abnormal / high / low
--     AA, HH, LL CRITICALLY abnormal / high / low
--
-- That AA/HH/LL tier is exactly the distinction CLIA 42 CFR 493.1109(f) and
-- ISO 15189:2022 7.4.1.3 treat as a different class of event requiring immediate
-- notification. Conflating "high" with "critically high" on screen defeats the
-- notification the laboratory is obliged to make.
--
-- WHY IT IS NULLABLE
-- Results stored before this column existed have no code, and a laboratory may
-- send an interpretation with no coding at all. Null means "not stated", and the
-- display falls back to showing the label with no severity treatment rather than
-- guessing a severity it was not told.
-- =============================================================================

SET search_path TO his;

ALTER TABLE his.lab_results_summary
    ADD COLUMN IF NOT EXISTS interpretation_code varchar(16);

COMMENT ON COLUMN his.lab_results_summary.interpretation_code IS
    'HL7 v3 ObservationInterpretation code (N, A, H, L, AA, HH, LL). Drives '
    'severity display; interpretation holds the laboratory''s own wording.';

GRANT SELECT, INSERT, UPDATE ON his.lab_results_summary TO his_app;
