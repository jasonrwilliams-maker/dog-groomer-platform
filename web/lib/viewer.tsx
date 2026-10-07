"use client";

import { createContext, useContext } from "react";

// Who is using the screen, so the words fit them: a manager is told a copy is
// on their own to-do list, a groomer that a manager will review it. Picking a
// name is not security (see the README); this only chooses wording.
const ManagerContext = createContext(false);

export const ViewerProvider = ManagerContext.Provider;

export function useIsManager(): boolean {
  return useContext(ManagerContext);
}
