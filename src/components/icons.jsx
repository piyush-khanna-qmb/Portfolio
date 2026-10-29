import React from "react";

/**
 * Shared stroke-style glyph set, so a capability pill, a prompt row and
 * a decomposition step all draw the same icon for the same concept.
 * Everything here is designed for `fill="none" stroke="currentColor"`.
 */
const P = ({ d }) => <path d={d} />;

export const ICONS = {
  app: <><rect x='3' y='3' width='7' height='7' rx='1.5' /><rect x='14' y='3' width='7' height='7' rx='1.5' /><rect x='3' y='14' width='7' height='7' rx='1.5' /><rect x='14' y='14' width='7' height='7' rx='1.5' /></>,
  place: <><P d='M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0z' /><circle cx='12' cy='10' r='3' /></>,
  time: <><circle cx='12' cy='12' r='9' /><polyline points='12 7 12 12 15.5 14' /></>,
  bell: <><P d='M18 8a6 6 0 0 0-12 0c0 7-3 9-3 9h18s-3-2-3-9' /><P d='M13.7 21a2 2 0 0 1-3.4 0' /></>,
  volume: <><polygon points='11 5 6 9 2 9 2 15 6 15 11 19 11 5' /><P d='M15.5 8.5a5 5 0 0 1 0 7' /><P d='M18.5 5.5a9 9 0 0 1 0 13' /></>,
  bolt: <polygon points='13 2 3 14 11 14 11 22 21 10 13 10 13 2' />,
  alarm: <><circle cx='12' cy='13' r='8' /><polyline points='12 9 12 13 15 15' /><P d='M5 3 2 6' /><P d='M19 3l3 3' /></>,
  timer: <><circle cx='12' cy='14' r='7' /><P d='M9 2h6' /><P d='M12 11v3' /></>,
  phone: <P d='M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 1.9.7 2.8a2 2 0 0 1-.5 2.1L8.1 9.9a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.8.7a2 2 0 0 1 1.7 2z' />,
  sms: <P d='M21 11.5a8.4 8.4 0 0 1-9 8.4 8.5 8.5 0 0 1-3.8-.9L3 21l2-4.2A8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z' />,
  mail: <><rect x='2' y='4' width='20' height='16' rx='2' /><polyline points='22,6 12,13 2,6' /></>,
  link: <><P d='M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7' /><P d='M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7' /></>,
  settings: <><line x1='4' y1='21' x2='4' y2='14' /><line x1='4' y1='10' x2='4' y2='3' /><line x1='12' y1='21' x2='12' y2='12' /><line x1='12' y1='8' x2='12' y2='3' /><line x1='20' y1='21' x2='20' y2='16' /><line x1='20' y1='12' x2='20' y2='3' /><line x1='1' y1='14' x2='7' y2='14' /><line x1='9' y1='8' x2='15' y2='8' /><line x1='17' y1='16' x2='23' y2='16' /></>,
  torch: <><P d='M6 2h12l-2 5H8L6 2z' /><P d='M8 7h8v4l-2 2v9h-4v-9l-2-2V7z' /></>,

  /* decomposition-step glyphs */
  unlock: <><rect x='3' y='11' width='18' height='11' rx='2' /><P d='M7 11V7a5 5 0 0 1 9.9-1' /></>,
  bulb: <><P d='M9 18h6' /><P d='M10 22h4' /><P d='M12 2a7 7 0 0 0-4 12.7V17h8v-2.3A7 7 0 0 0 12 2z' /></>,
  news: <><P d='M4 4h13v16H4z' /><P d='M17 8h3v10a2 2 0 0 1-3 0' /><line x1='7' y1='8' x2='14' y2='8' /><line x1='7' y1='12' x2='14' y2='12' /><line x1='7' y1='16' x2='11' y2='16' /></>,
  route: <><circle cx='6' cy='19' r='3' /><circle cx='18' cy='5' r='3' /><P d='M9 19h6a4 4 0 0 0 0-8H9a4 4 0 0 1 0-8h0' /></>,
  calendar: <><rect x='3' y='5' width='18' height='16' rx='2' /><line x1='3' y1='10' x2='21' y2='10' /><line x1='8' y1='3' x2='8' y2='7' /><line x1='16' y1='3' x2='16' y2='7' /></>,
  tasks: <><polyline points='3 7 5 9 9 5' /><polyline points='3 16 5 18 9 14' /><line x1='13' y1='7' x2='21' y2='7' /><line x1='13' y1='16' x2='21' y2='16' /></>,
  speed: <><P d='M12 15a3 3 0 1 0 0-6' /><P d='M4 19a10 10 0 1 1 16 0' /><line x1='14.5' y1='11.5' x2='18' y2='8' /></>,
  moon: <P d='M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z' />,
  eye: <><P d='M1 12s4-7 11-7 11 7 11 7-4 7-11 7-11-7-11-7z' /><circle cx='12' cy='12' r='3' /></>,
  shield: <P d='M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z' />,
  book: <><P d='M4 19.5A2.5 2.5 0 0 1 6.5 17H20' /><P d='M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z' /></>,
  check: <polyline points='20 6 9 17 4 12' />,
};

export const Glyph = ({ name, className = "w-[15px] h-[15px]" }) => (
  <svg
    viewBox='0 0 24 24'
    fill='none'
    stroke='currentColor'
    strokeWidth={1.8}
    strokeLinecap='round'
    strokeLinejoin='round'
    className={className}
    aria-hidden='true'
  >
    {ICONS[name] || ICONS.bolt}
  </svg>
);

export default Glyph;
