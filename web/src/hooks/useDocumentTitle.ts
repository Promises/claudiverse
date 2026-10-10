import { useEffect } from "react";

const PRODUCT = "Claudiverse";

/**
 * The browser tab's title: "<page> · Claudiverse", or just "Claudiverse" when
 * there is no page name (yet — a seat's title arrives after its fetch).
 * Restores the plain product name on unmount, so a page never leaves its own
 * title behind on the next one.
 */
export function useDocumentTitle(page?: string | null) {
  useEffect(() => {
    document.title = page ? `${page} · ${PRODUCT}` : PRODUCT;
    return () => {
      document.title = PRODUCT;
    };
  }, [page]);
}
