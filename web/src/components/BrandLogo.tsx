import logo from "../assets/logo.svg";
import logoDark from "../assets/logo-dark.svg";
import styles from "./BrandLogo.module.css";

/**
 * The Claudiverse mark, for the start of a page heading. The heading text
 * already names the product, so the image is decorative (alt=""). Follows the
 * OS theme, like the colour tokens in index.css.
 */
export default function BrandLogo() {
  return (
    <picture className={styles.mark}>
      <source srcSet={logoDark} media="(prefers-color-scheme: dark)" />
      <img src={logo} alt="" width={22} height={22} />
    </picture>
  );
}
