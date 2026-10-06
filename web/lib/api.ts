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
  allergies: { allergen: string; severity: number; severity_label: string; source: string; note: string | null }[];
  behaviour: { difficulty: number; difficulty_label: string; zone: string | null; trigger: string | null;
               note: string | null; observed_on: string }[];
  last_visit: { visit_date: string; groomer: string; note: string | null } | null;
  open_visit: { id: string; check_in: string; groomer: string } | null;
  paperwork_requests: { vaccine: string; status: string; channel: string; next_reminder_on: string | null }[];
};

export type Groomer = { id: string; name: string; role: "groomer" | "manager" };

/** Where a search looks: the dog's name, the owner's, or either. */
export type SearchBy = "any" | "dog" | "owner";

export type ComplianceLine = {
  dog_id: string; dog: string; owner: string; vaccine: string; state: string; label: string;
  expires_on: string | null; days_until_expiry: number | null; blocks_service: boolean;
  request_status: string | null;
};

export type ComplianceSummary = { dogs: number; cleared: number; blocked: number; lines: ComplianceLine[] };

export type WalkInOptions = {
  coats: { code: string; name: string }[];
  breeds: { name: string; coat: string }[];
  vaccines: { code: string; name: string; required: boolean }[];
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
  const r = await fetch(`/api${path}`, {
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
  /** A new dog, for an owner on file (ownerId) or a new one (owner). */
  addWalkIn: (groomerId: string, dog: NewDog, owner: { id: string } | NewOwner) =>
    post<{ owner_id: string; dog_id: string }>("/walk-ins", {
      groomer_id: groomerId, dog, ...("id" in owner ? { owner_id: owner.id } : { owner }),
    }),
  addShot: (dogId: string, groomerId: string, vaccine: string, administeredOn: string | null, expiresOn: string | null) =>
    post<{ id: string }>(`/dogs/${dogId}/shots`, {
      groomer_id: groomerId, vaccine, administered_on: administeredOn, expires_on: expiresOn,
    }),
};
