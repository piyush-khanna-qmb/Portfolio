import { motion } from "framer-motion";

import { styles } from "../styles";
import { staggerContainer } from "../utils/motion";

/**
 * `amount` is a fraction of the SECTION'S OWN height, not the viewport's.
 * That's fine for sections short enough to fit a mobile viewport, but a
 * section whose content stacks tall on narrow screens (e.g. a card grid
 * that goes from a multi-column row on desktop to one full-width column
 * on mobile) can end up needing more px visible than a phone screen is
 * tall, so the threshold is never reached and it never animates. Callers
 * with that shape should pass a smaller `viewportAmount`.
 */
const StarWrapper = (Component, idName, viewportAmount = 0.25) =>
  function HOC() {
    return (
      <motion.section
        variants={staggerContainer()}
        initial='hidden'
        whileInView='show'
        viewport={{ once: true, amount: viewportAmount }}
        className={`${styles.padding} max-w-7xl mx-auto relative z-0`}
      >
        <span className='hash-span' id={idName}>
          &nbsp;
        </span>

        <Component />
      </motion.section>
    );
  };

export default StarWrapper;
