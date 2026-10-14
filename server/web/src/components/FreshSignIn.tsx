import { useAuth } from "../contexts/AuthContext";
import styles from "./FreshSignIn.module.css";

/**
 * In place of the server's raw app-only refusal: this sign-in cannot do what
 * the page offers (it predates the panel asking for an app sign-in), and how
 * to get one that can.
 */
export default function FreshSignIn() {
  const { logout } = useAuth();
  return (
    <div className={styles.notice} role="alert">
      <span className={styles.text}>This page needs a fresh sign-in: sign out and sign in again.</span>
      <button className={styles.button} onClick={() => void logout()}>
        Sign out
      </button>
    </div>
  );
}
