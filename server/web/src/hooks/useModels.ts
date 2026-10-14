import { useEffect, useState } from "react";
import { getModels } from "../api/models";
import { BUILT_IN, type ModelList } from "../lib/models";

/**
 * The server's model list (GET /api/models), read once per page; the built-in
 * copy until it arrives, and if it cannot be read.
 */
export function useModels(): ModelList {
  const [list, setList] = useState<ModelList>(BUILT_IN);
  useEffect(() => {
    let gone = false;
    getModels()
      .then((l) => {
        if (!gone) setList(l);
      })
      .catch(() => {});
    return () => {
      gone = true;
    };
  }, []);
  return list;
}
