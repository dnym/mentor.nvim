-- Stored timestamps are wall-clock epoch milliseconds from here on; earlier
-- rows hold monotonic readings (milliseconds since boot) that cannot be
-- converted. Views render those as "date unknown". A snooze stored that way
-- would be compared against wall-clock time and never expire on its own
-- terms, so it is cleared. Open usage reservations resolve themselves: the
-- startup sweep sees them as old and folds or releases them.
UPDATE observation_pref SET snooze_until = 0
    WHERE snooze_until > 0 AND snooze_until < 946684800000;

-- Why a finding did not interrupt (the notification policy's reason), so the
-- list can explain a silent finding. Cleared once it does notify.
ALTER TABLE observation ADD COLUMN notify_note TEXT;
