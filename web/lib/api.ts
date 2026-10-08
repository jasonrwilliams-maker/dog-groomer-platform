// What the backend returns (api/app/main.py), and the calls the screen makes.

export type DogSummary = {
  id: string;
  name: string;
  breed: string | null;
  owner: string;
  state: string;
  label: string;
  blocks_service: boolean;
  attention: string | null;
};

export type VaccineLine = {
  code: string;
  vaccine: string;
  state: string;
  label: string;
  expires_on: string | null;
  days_until_expiry: number | null;
  blocks_service: boolean;
  regulatory_required: boolean;
  /** Set when the record was typed in by someone reading a photo of the paperwork. */
  hand_checked: {
    checked_by: string; checked_on: string; second_look: boolean; document_id: string;
    /** The manager who put its dates right, if they were misread. */
    fixed_by: string | null;
  } | null;
};

export type CheckInCard = {
  dog: {
    id: string; name: string; sex: string; breed: string | null; coat: string; age: string | null;
    owner: string; phone: string | null; email: string | null;
  };
  household: { owner_id: string; other_dogs: string[] };
  /** What the edit form starts from: the parts, not the label. */
  profile: {
    first_name: string; last_name: string; phone: string | null; email: string | null;
    name: string; breed: string | null; is_mixed: boolean; second_breed: string | null; coat: string;
    sex: "male" | "female" | "unknown"; date_of_birth: string | null;
  };
  can_start: boolean;
  blocking: string[];
  vaccines: VaccineLine[];
  allergies: Allergy[];
  behaviour: BehaviourNote[];
  last_visit: { visit_date: string; groomer: string; note: string | null } | null;
  open_visit: { id: string; check_in: string; groomer: string } | null;
  paperwork_requests: { vaccine: string; status: string; channel: string; next_reminder_on: string | null }[];
  /** Copies taken at the counter that nobody has finished checking. */
  paperwork_waiting: { document_id: string; mime_type: string; received_by: string; received_at: string }[];
  /** Grooms booked from today on. */
  appointments: { id: string; groomer: string; starts_at: string; ends_at: string; minutes: number; service: string; note: string | null }[];
  /** Whoever groomed the dog last (or first booked it); null for a new client. */
  usual_groomer: { id: string; name: string } | null;
};

/** What the counter's upload saved. */
export type ReceivedCopy = {
  document_id: string; mime_type: string; page_count: number;
  original_bytes: number; saved_bytes: number;
  /** Whether any photo was made smaller to save space. */
  resized: boolean;
};
export type WaitingCopy = {
  document_id: string; dog_id: string; dog: string; owner: string; mime_type: string;
  page_count: number | null; received_by: string; received_at: string;
  /** The AI has read it, so the form will come filled in. */
  ai_read: boolean;
};
export type HandChecked = {
  id: string; dog_id: string; dog: string; owner: string; vaccine: string; administered_on: string;
  expires_on: string; document_id: string; mime_type: string; checked_by: string; checked_at: string;
};
/** One thing on the calendar: a groom that happened, or a vaccine running out. */
export type CalendarEvent = {
  on_date: string; kind: "groom" | "expiry" | "booking"; dog_id: string; dog: string; owner: string;
  vaccine: string | null; groomer: string | null; note: string | null;
  /** The vaccine's lapse stops a groom (rabies, as the shop is set up). */
  stops_grooms: boolean;
  /** A groom that started today and isn't finished. */
  in_progress: boolean;
  /** A booking: which one, its start (hh:mm:ss), length and service. A groom has its check-in time. */
  appointment_id: string | null; starts_at: string | null; minutes: number | null; service: string | null;
};

/** Something the shop offers, and how long it usually takes. */
export type Service = { code: string; name: string; default_minutes: number };
export type ShopHours = { opens: string; closes: string; today: string; step: number };
/** One groomer as a choice for a booking: the usual one comes first. */
export type BookingChoice = {
  groomer_id: string; groomer: string; is_regular: boolean; last_groomed_on: string | null;
  /** Start times (shop time, yyyy-mm-ddThh:mm:ss) free for a groom this long. */
  free_starts: string[];
};
/** What will be out of date about the dog's vaccines by the booking. A warning only. */
export type BookingWarning = { vaccine: string; expires_on: string | null; warning: string };
export type Appointment = {
  id: string; dog_id: string; dog: string; owner: string; groomer_id: string; groomer: string;
  service_code: string; service: string; starts_at: string; ends_at: string; minutes: number;
  note: string | null; other_groomer_reason: string | null; not_usual_groomer: boolean;
};
export type NewBooking = {
  dog_id: string; groomer_id: string; starts_at: string; minutes: number; service: string;
  note: string | null; other_groomer_reason: string | null; booked_by: string;
};
/** A shot typed in with no copy of the paperwork, waiting for a manager to verify it. */
export type WaitingShot = {
  id: string; dog_id: string; dog: string; owner: string; vaccine: string; administered_on: string;
  expires_on: string; entered_by: string | null; entered_at: string;
};

/** What the AI read for one vaccine, to fill the form in from. */
export type AiSuggestion = {
  vaccine_code: string; line_item_id: string; term: string;
  administered_on: string | null; administered_on_raw: string | null;
  expires_on: string | null; expires_on_raw: string | null;
  /** The page prints less than a full date, or nothing, behind the date the AI gave. */
  given_doubtful: boolean; expires_doubtful: boolean;
};
/** A name the AI found that nobody has said which vaccine it is. */
export type AiUnfamiliar = { line_item_id: string; term: string; administered_on_raw: string | null; expires_on_raw: string | null };
export type AiState =
  | { reading: null }
  | {
      reading: { id: string; extracted_at: string; model_version: string; status: string; failed: boolean };
      suggestions: Record<string, AiSuggestion>;
      unfamiliar: AiUnfamiliar[];
    };
/** Which AI reading, and which of its lines, a saved vaccine answers. */
export type AiVerdict = { ai_extraction_id: string; ai_line_item_id: string | null };
export type AiAccuracy = {
  copy_kind: "photo" | "pdf"; readings: number; dates_checked: number;
  right_first_time: number; read_wrong: number; missed: number; made_up: number;
};

/** Where the screen shows a copy from. */
export const paperworkUrl = (documentId: string) => `/api/paperwork/${documentId}/file`;
/** One page of a copy, as an image. */
export const pageUrl = (documentId: string, page: number) => `/api/paperwork/${documentId}/pages/${page}`;

export type Groomer = { id: string; name: string; role: "groomer" | "manager" };

/** Where a search looks: the dog's name, the owner's, or either. */
export type SearchBy = "any" | "dog" | "owner";

export type ComplianceLine = {
  dog_id: string; dog: string; owner: string; vaccine: string; state: string; label: string;
  expires_on: string | null; days_until_expiry: number | null; blocks_service: boolean;
  request_status: string | null;
};

export type ComplianceSummary = { dogs: number; cleared: number; blocked: number; lines: ComplianceLine[] };

export type AllergyType = "contact" | "flea" | "environmental" | "food";
export type AllergySource = "owner_reported" | "observed" | "vet_documented";
export type Allergy = {
  id: string; allergen: string; type: AllergyType; severity: number; severity_label: string;
  source: AllergySource; note: string | null;
};
export type BehaviourNote = {
  id: string; difficulty: number; difficulty_label: string; zone: string | null; zone_code: string | null;
  trigger: string | null; note: string | null; observed_on: string; observed_by: string | null;
};
export type NewBehaviour = { difficulty: number; trigger: string | null; zone: string | null; note: string | null };
export type Review = {
  id: string; dog_id: string; dog: string; owner: string; summary: string; reason: string;
  changed_by: string; changed_at: string;
};

export type WalkInOptions = {
  coats: { code: string; name: string }[];
  breeds: { name: string; coat: string }[];
  vaccines: { code: string; name: string; required: boolean }[];
  allergens: { name: string; type: AllergyType }[];
  zones: { code: string; name: string }[];
};

export type NewOwner = { first_name: string; last_name: string; phone: string | null; email: string | null };
export type NewDog = {
  name: string; breed: string | null; coat: string | null;
  /** A mix: of second_breed, or of something unknown when that is blank. */
  is_mixed: boolean; second_breed: string | null;
  /** The groomer says this breed really is missing from the list. */
  new_breed: boolean;
  sex: "male" | "female" | "unknown" | null; date_of_birth: string | null;
};

export type BreedSuggestion = { name: string; coat: string };
/** What an edit changed, as the audit log records it. */
export type Changed = Record<string, { old: unknown; new: unknown }>;

/** A refusal from the database, passed through by the backend as a 409. */
export class Refusal extends Error {
  constructor(public code: string, message: string, public hint: string | null) {
    super(message);
  }
}

async function get<T>(path: string): Promise<T> {
  const r = await fetch(`/api${path}`, { cache: "no-store" });
  if (!r.ok) throw new Error(`The backend answered ${r.status} for ${path}.`);
  return r.json();
}

/** POST or PUT, and a 409 becomes a Refusal carrying the database's own words. */
async function send<T>(method: "POST" | "PUT", path: string, body: unknown): Promise<T> {
  // A form (a file upload) goes as it is; anything else as JSON.
  const r = await fetch(`/api${path}`, body instanceof FormData ? { method, body } : {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await r.json().catch(() => ({}));
  if (r.status === 409) throw new Refusal(json.code, json.message, json.hint);
  if (!r.ok) throw new Error(typeof json.detail === "string" ? json.detail : `The backend answered ${r.status}.`);
  return json as T;
}
const post = <T,>(path: string, body: unknown) => send<T>("POST", path, body);

export const api = {
  groomers: () => get<Groomer[]>("/groomers"),
  findDogs: (q: string, by: SearchBy = "any") => get<DogSummary[]>(`/dogs?q=${encodeURIComponent(q)}&by=${by}`),
  compliance: () => get<ComplianceSummary>("/admin/compliance"),
  card: (id: string) => get<CheckInCard>(`/dogs/${id}`),
  startGroom: (dogId: string, groomerId: string) =>
    post<{ id: string; visit_date: string; check_in: string; groomer: string }>(
      `/dogs/${dogId}/visits`, { groomer_id: groomerId }),
  walkInOptions: () => get<WalkInOptions>("/walk-in/options"),
  suggestBreeds: (q: string) => get<BreedSuggestion[]>(`/breeds/suggest?q=${encodeURIComponent(q)}`),
  editOwner: (ownerId: string, groomerId: string, owner: NewOwner) =>
    send<{ changed: Changed }>("PUT", `/owners/${ownerId}`, { groomer_id: groomerId, ...owner }),
  editDog: (dogId: string, groomerId: string, dog: NewDog) =>
    send<{ changed: Changed }>("PUT", `/dogs/${dogId}`, { groomer_id: groomerId, ...dog }),
  suggestAllergens: (q: string) => get<{ name: string; type: AllergyType }[]>(`/allergens/suggest?q=${encodeURIComponent(q)}`),
  addAllergy: (dogId: string, groomerId: string, a: {
    allergen: string; severity: number; source: AllergySource; note: string | null;
    new_allergen: boolean; type: AllergyType | null;
  }) => post<{ id: string }>(`/dogs/${dogId}/allergies`, { groomer_id: groomerId, ...a }),
  editAllergy: (id: string, groomerId: string, a: { severity: number; source: AllergySource; note: string | null; reason: string | null }) =>
    send<{ changed: Changed }>("PUT", `/allergies/${id}`, { groomer_id: groomerId, ...a }),
  removeAllergy: (id: string, groomerId: string, reason: string) =>
    post<{ removed: boolean }>(`/allergies/${id}/remove`, { groomer_id: groomerId, reason }),
  addBehaviour: (dogId: string, groomerId: string, b: NewBehaviour) =>
    post<{ id: string }>(`/dogs/${dogId}/behaviour`, { groomer_id: groomerId, ...b }),
  correctBehaviour: (id: string, groomerId: string, b: NewBehaviour) =>
    send<{ changed: Changed }>("PUT", `/behaviour/${id}`, { groomer_id: groomerId, ...b }),
  reviews: () => get<Review[]>("/admin/reviews"),
  markReviewed: (id: string, groomerId: string) =>
    post<{ reviewed: boolean }>(`/admin/reviews/${id}/reviewed`, { groomer_id: groomerId }),
  /** A new dog, for an owner on file (ownerId) or a new one (owner). */
  addWalkIn: (groomerId: string, dog: NewDog, owner: { id: string } | NewOwner) =>
    post<{ owner_id: string; dog_id: string }>("/walk-ins", {
      groomer_id: groomerId, dog, ...("id" in owner ? { owner_id: owner.id } : { owner }),
    }),
  aiStatus: () => get<{ available: boolean; why_not: string | null }>("/ai/status"),
  aiState: (documentId: string) => get<AiState>(`/paperwork/${documentId}/ai`),
  /** Send the copy to the AI. Up to a minute or so. */
  aiRead: (documentId: string, groomerId: string) =>
    post<AiState>(`/paperwork/${documentId}/ai`, { groomer_id: groomerId }),
  /** Say which vaccine a name the AI found is (null: not one the shop tracks). */
  ruleOnTerm: (documentId: string, groomerId: string, term: string, vaccine: string | null) =>
    post<AiState>(`/paperwork/${documentId}/ai/terms`, { groomer_id: groomerId, term, vaccine }),
  aiAccuracy: () => get<AiAccuracy[]>("/admin/ai-accuracy"),
  addShot: (dogId: string, groomerId: string, vaccine: string, administeredOn: string | null, expiresOn: string | null) =>
    post<{ id: string }>(`/dogs/${dogId}/shots`, {
      groomer_id: groomerId, vaccine, administered_on: administeredOn, expires_on: expiresOn,
    }),
  /** A photo or PDF of the owner's paperwork, kept with the dog. */
  sendPaperwork: (dogId: string, groomerId: string, files: File[]) => {
    const form = new FormData();
    form.append("groomer_id", groomerId);
    files.forEach((f) => form.append("files", f));
    return post<ReceivedCopy>(`/dogs/${dogId}/paperwork`, form);
  },
  paperworkInfo: (documentId: string) => get<{ mime_type: string; page_count: number }>(`/paperwork/${documentId}`),
  /** One page out of a copy nobody has checked a shot against. */
  removePage: (dogId: string, documentId: string, page: number, groomerId: string) =>
    post<{ page_count: number }>(`/dogs/${dogId}/paperwork/${documentId}/pages/${page}/remove`, { groomer_id: groomerId }),
  /** A copy nobody has checked a shot against, taken off the dog. */
  removePaperwork: (dogId: string, documentId: string, groomerId: string) =>
    post<{ removed: boolean }>(`/dogs/${dogId}/paperwork/${documentId}/remove`, { groomer_id: groomerId }),
  /** A shot typed in while reading the photo: verified, and marked checked by hand. */
  addCheckedShot: (dogId: string, groomerId: string, documentId: string, vaccine: string,
                   administeredOn: string | null, expiresOn: string | null, ai?: AiVerdict) =>
    post<{ id: string }>(`/dogs/${dogId}/checked-shots`, {
      groomer_id: groomerId, document_id: documentId, vaccine, administered_on: administeredOn, expires_on: expiresOn,
      ...ai,
    }),
  /** A vaccine the paperwork doesn't show: the shop asks the owner for it. */
  askOwner: (dogId: string, groomerId: string, vaccine: string, ai?: AiVerdict) =>
    post<{ id: string }>(`/dogs/${dogId}/ask-owner`, { groomer_id: groomerId, vaccine, ...ai }),
  paperworkDone: (dogId: string, documentId: string, groomerId: string) =>
    post<{ done: boolean }>(`/dogs/${dogId}/paperwork/${documentId}/done`, { groomer_id: groomerId }),
  paperworkWaiting: () => get<WaitingCopy[]>("/admin/paperwork"),
  handChecked: () => get<HandChecked[]>("/admin/hand-checked"),
  secondLook: (recordId: string, groomerId: string) =>
    post<{ looked: boolean }>(`/admin/hand-checked/${recordId}/looked`, { groomer_id: groomerId }),
  /** Grooms and expiries between two dates (yyyy-mm-dd), or one dog's whole history. */
  calendar: (span: { start: string; end: string } | { dogId: string }) =>
    get<CalendarEvent[]>("dogId" in span ? `/calendar?dog_id=${span.dogId}` : `/calendar?start=${span.start}&end=${span.end}`),
  services: () => get<Service[]>("/services"),
  shopHours: () => get<ShopHours>("/booking/hours"),
  bookingChoices: (dogId: string, startsAt: string, minutes: number, ignore?: string) =>
    get<{ choices: BookingChoice[]; warnings: BookingWarning[] }>(
      `/booking/choices?dog_id=${dogId}&starts_at=${startsAt}&minutes=${minutes}${ignore ? `&ignore=${ignore}` : ""}`),
  dayAppointments: (day: string) => get<Appointment[]>(`/appointments?day=${day}`),
  book: (b: NewBooking) => post<{ id: string }>("/appointments", b),
  changeBooking: (id: string, b: Omit<NewBooking, "dog_id" | "service">) =>
    send<{ changed: boolean }>("PUT", `/appointments/${id}`, b),
  cancelBooking: (id: string, groomerId: string, reason: string) =>
    post<{ cancelled: boolean }>(`/appointments/${id}/cancel`, { groomer_id: groomerId, reason }),
  waitingVerification: () => get<WaitingShot[]>("/admin/waiting-verification"),
  /** A manager puts a shot's dates right. */
  fixRecord: (recordId: string, groomerId: string, administeredOn: string, expiresOn: string) =>
    post<{ fixed: boolean }>(`/admin/records/${recordId}/fix`, {
      groomer_id: groomerId, administered_on: administeredOn || null, expires_on: expiresOn || null }),
  /** A manager verifies a shot typed in with no photo, with any fix to its dates. */
  verifyRecord: (recordId: string, groomerId: string, how: string, administeredOn: string, expiresOn: string) =>
    post<{ verified: boolean }>(`/admin/records/${recordId}/verify`, {
      groomer_id: groomerId, how, administered_on: administeredOn || null, expires_on: expiresOn || null }),
};
