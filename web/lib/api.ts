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

export type Groomer = { id: string; name: string };

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

export const api = {
  groomers: () => get<Groomer[]>("/groomers"),
  findDogs: (q: string) => get<DogSummary[]>(`/dogs?q=${encodeURIComponent(q)}`),
  card: (id: string) => get<CheckInCard>(`/dogs/${id}`),
  async startGroom(dogId: string, groomerId: string) {
    const r = await fetch(`/api/dogs/${dogId}/visits`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ groomer_id: groomerId }),
    });
    const body = await r.json();
    if (r.status === 409) throw new Refusal(body.code, body.message, body.hint);
    if (!r.ok) throw new Error(body.detail ?? `The backend answered ${r.status}.`);
    return body as { id: string; visit_date: string; check_in: string; groomer: string };
  },
};
