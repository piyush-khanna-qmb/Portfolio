import { styles } from "../styles";

const socials = [
  {
    name: "LinkedIn",
    href: "https://www.linkedin.com/in/piyush-khanna-qmb/",
    icon: (
      <>
        <path d="M16 8a6 6 0 0 1 6 6v7h-4v-7a2 2 0 0 0-2-2 2 2 0 0 0-2 2v7h-4v-7a6 6 0 0 1 6-6z" />
        <rect x="2" y="9" width="4" height="12" />
        <circle cx="4" cy="4" r="2" />
      </>
    ),
  },
  {
    name: "GitHub",
    href: "https://github.com/piyush-khanna-qmb/",
    icon: (
      <path d="M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 4.77 5.07 5.07 0 0 0 19.91 1S18.73.65 16 2.48a13.38 13.38 0 0 0-7 0C6.27.65 5.09 1 5.09 1A5.07 5.07 0 0 0 5 4.77a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7A3.37 3.37 0 0 0 9 18.13V22" />
    ),
  },
  {
    name: "Instagram",
    href: "https://www.instagram.com/highonelixir/",
    icon: (
      <>
        <rect x="2" y="2" width="20" height="20" rx="5" ry="5" />
        <path d="M16 11.37A4 4 0 1 1 12.63 8 4 4 0 0 1 16 11.37z" />
        <line x1="17.5" y1="6.5" x2="17.51" y2="6.5" />
      </>
    ),
  },
  {
    name: "WhatsApp",
    href: "https://wa.me/918755122371",
    /* The recognisable WhatsApp mark is a filled glyph, so this one opts
       out of the outline treatment the others share. */
    solid: true,
    icon: (
      <path d="M12.04 2c-5.46 0-9.91 4.45-9.91 9.91 0 1.75.46 3.45 1.32 4.95L2 22l5.25-1.38a9.87 9.87 0 0 0 4.79 1.22h.01c5.46 0 9.91-4.45 9.91-9.91 0-2.65-1.03-5.14-2.9-7.01A9.82 9.82 0 0 0 12.04 2zm0 18.13h-.01a8.2 8.2 0 0 1-4.19-1.15l-.3-.18-3.12.82.83-3.04-.2-.31a8.22 8.22 0 0 1-1.26-4.36c0-4.54 3.7-8.23 8.25-8.23 2.2 0 4.27.86 5.83 2.42a8.19 8.19 0 0 1 2.41 5.82c0 4.54-3.7 8.21-8.24 8.21zm4.52-6.16c-.25-.12-1.47-.72-1.69-.81-.23-.08-.39-.12-.56.13-.16.25-.64.81-.78.97-.14.17-.29.19-.54.06-.25-.12-1.05-.39-1.99-1.23-.74-.66-1.23-1.47-1.38-1.72-.14-.25-.01-.38.11-.51.11-.11.25-.29.37-.43.13-.15.17-.25.25-.41.08-.17.04-.31-.02-.43-.06-.12-.56-1.34-.76-1.84-.2-.48-.41-.42-.56-.43h-.48c-.17 0-.43.06-.66.31-.23.25-.86.85-.86 2.07 0 1.22.89 2.4 1.01 2.56.12.17 1.75 2.67 4.23 3.74.59.26 1.05.41 1.41.52.59.19 1.13.16 1.56.1.47-.07 1.47-.6 1.67-1.18.21-.58.21-1.07.15-1.18-.06-.11-.23-.17-.48-.29z" />
    ),
  },
];

const Footer = () => {
  return (
    <section className="relative w-full">
      <div
        className={`max-w-7xl mx-auto ${styles.paddingX} py-9 flex flex-col items-center gap-[18px]`}
      >
        <nav
          aria-label="Social links"
          className="flex items-center justify-center flex-wrap gap-3 sm:gap-4"
        >
          {socials.map(({ name, href, icon, solid }) => (
            <a
              key={name}
              href={href}
              target="_blank"
              rel="noopener noreferrer"
              aria-label={name}
              className="w-10 h-10 sm:w-11 sm:h-11 rounded-full flex items-center justify-center black-gradient text-white transition-all duration-300 hover:-translate-y-0.5 hover:shadow-[0_0_18px_rgba(145,94,255,0.55)]"
            >
              <svg
                viewBox="0 0 24 24"
                className="w-[18px] h-[18px] sm:w-5 sm:h-5"
                fill={solid ? "currentColor" : "none"}
                stroke={solid ? "none" : "currentColor"}
                strokeWidth={1.8}
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                {icon}
              </svg>
            </a>
          ))}

          <a
            href="mailto:piyushkhannavb@gmail.com"
            aria-label="Email"
            className="w-10 h-10 sm:w-11 sm:h-11 rounded-full flex items-center justify-center black-gradient text-white transition-all duration-300 hover:-translate-y-0.5 hover:shadow-[0_0_18px_rgba(145,94,255,0.55)]"
          >
            <svg
              viewBox="0 0 24 24"
              className="w-[18px] h-[18px] sm:w-5 sm:h-5"
              fill="none"
              stroke="currentColor"
              strokeWidth={1.8}
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <rect x="2" y="4" width="20" height="16" rx="2" ry="2" />
              <polyline points="22,6 12,13 2,6" />
            </svg>
          </a>
        </nav>

        <p className="text-secondary text-[13px]">
          &copy; {new Date().getFullYear()}{" "}
          <span className="text-white font-semibold">Piyush Khanna</span>
        </p>
      </div>
    </section>
  );
};

export default Footer;
