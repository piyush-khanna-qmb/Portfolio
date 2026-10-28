import React from "react";

/**
 * The single link affordance used across the site: a diagonal arrow
 * pointing up and to the right, in the accent purple.
 *
 * Every outbound or forward-navigating link uses this, so the gesture
 * reads the same everywhere. The only exception is the "back to
 * portfolio" link in PageShell, which points left on purpose.
 */
const ArrowUpRight = ({ className = "w-4 h-4" }) => (
  <svg
    viewBox='0 0 24 24'
    fill='none'
    stroke='currentColor'
    strokeWidth={2}
    strokeLinecap='round'
    strokeLinejoin='round'
    className={className}
    aria-hidden='true'
  >
    <line x1='7' y1='17' x2='17' y2='7' />
    <polyline points='7 7 17 7 17 17' />
  </svg>
);

export default ArrowUpRight;
