42 rules.

| Code | What it refuses | Added in |
|---|---|---|
| GR001 | Remedial cut without a qualifying coat assessment | `grooming_platform_schema.sql` |
| GR002 | Approved remedial override with no coat level stated | `grooming_platform_schema.sql` |
| GR003 | Uniform-length template resolved to more than one length | `grooming_platform_schema.sql` |
| GR004 | Cut specification on a visit with no groom service | `grooming_platform_schema.sql` |
| GR005 | Email reminder to an owner who opted out | `grooming_platform_schema.sql` |
| GR006 | Template zone spec configured outside its clamp | `grooming_platform_schema.sql` |
| GR007 | Unknown style template | `grooming_platform_schema.sql` |
| GR008 | Remedial template saved as a standing style profile | `grooming_platform_schema.sql` |
| GR009 | Tiered template with no length tier | `grooming_platform_schema.sql` |
| GR010 | Length tier supplied to a non-tiered template | `grooming_platform_schema.sql` |
| GR011 | Haircut on a dog under the minimum grooming age, no approved reason | `grooming_platform_schema.sql` |
| GR012 | Regulatory vaccine rule changed without a stated reason | `grooming_platform_schema.sql` |
| GR013 | Shop_policy key missing or holding the wrong type | `grooming_platform_schema.sql` |
| GR014 | Attempt to delete a shop_policy row | `grooming_platform_schema.sql` |
| GR015 | The extraction is not awaiting review (already confirmed, rejected, or never loaded) | `18_confirmation.sql` |
| GR016 | The review is unfinished: a tracked vaccine line with a field nobody has checked, or a term nobody has ruled on | `18_confirmation.sql` |
| GR017 | The dog is not one this document is filed under | `18_confirmation.sql` |
| GR018 | A reviewed date is not usable: not a real calendar date, a shot in the future, or an expiry that is not after the shot | `18_confirmation.sql` |
| GR019 | An automated message to an owner who has not consented to that channel, or whose address for it is missing, or who opted out of email | `19_outreach.sql` |
| GR020 | A groom started for a dog whose service-blocking vaccine is expired, missing, disputed, or still being chased | `20_check_in.sql` |
| GR021 | A counter-entered shot whose dates cannot go on a vaccination record: no expiry, no date given, given in the future, or expiring before it was given | `22_walk_in.sql` |
| GR022 | A counter-entered shot that disagrees with one already on file for that dog: the same vaccine given within a few days, with different dates. Choosing between them is a manager's job. | `22_walk_in.sql` |
| GR023 | A breed that is not on the list, without saying it is a new one | `22_walk_in.sql` |
| GR024 | An allergen that is not on the list, without saying it is a new one | `24_allergies_and_handling.sql` |
| GR025 | An allergy taken off, or made less severe, without a reason | `24_allergies_and_handling.sql` |
| GR026 | A change marked reviewed by someone who is not a manager | `24_allergies_and_handling.sql` |
| GR027 | A shot checked by hand against a copy that is not on file for this dog | `26_counter_paperwork.sql` |
| GR028 | A second look given by someone who is not a manager | `26_counter_paperwork.sql` |
| GR029 | Removing a copy that a vaccination record was checked against | `26_counter_paperwork.sql` |
| GR030 | A shot verified or fixed by someone who is not a manager | `28_manager_fixes.sql` |
| GR031 | A booking over one the groomer, or the dog, already has | `30_appointments.sql` |
| GR032 | A regular client booked with another groomer, without saying why | `30_appointments.sql` |
| GR033 | A pelted coat shaved without the groomer saying she told the owner | `32_record_the_haircut.sql` |
| GR034 | A haircut that differs from the dog's usual style, with no reason | `32_record_the_haircut.sql` |
| GR035 | A haircut override OK'd by someone who is not a manager | `32_record_the_haircut.sql` |
| GR036 | Admin opened by someone who isn't a manager, with a wrong PIN, too many tries, or a passkey that isn't theirs | `33_admin_access.sql` |
| GR037 | A manager's PIN or passkeys changed by anyone but that manager, verified, or the last way in removed | `33_admin_access.sql` |
| GR038 | Staff changed by someone who isn't a manager with Admin open | `34_staff.sql` |
| GR039 | The shop left without an active manager | `34_staff.sql` |
| GR040 | A staff member deleted instead of marked as no longer working here | `34_staff.sql` |
| GR041 | Admin access reset for yourself, or for someone who isn't a manager | `34_staff.sql` |
| GR042 | Someone marked as gone while they still have grooms booked ahead | `34_staff.sql` |
