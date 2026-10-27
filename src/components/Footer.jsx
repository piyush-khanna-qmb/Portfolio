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
          {socials.map(({ name, href, icon }) => (
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
                fill="none"
                stroke="currentColor"
                strokeWidth={1.8}
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                {icon}
              </svg>
            </a>
          ))}

          <div className="relative group">
            <span
              tabIndex={0}
              aria-label="X (not currently used)"
              className="w-10 h-10 sm:w-11 sm:h-11 rounded-full flex items-center justify-center black-gradient text-white opacity-55 hover:opacity-85 transition-opacity duration-300 cursor-default"
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
                <line x1="4" y1="4" x2="20" y2="20" />
                <line x1="20" y1="4" x2="4" y2="20" />
              </svg>
            </span>
            <span className="pointer-events-none absolute left-1/2 top-full -translate-x-1/2 mt-2 whitespace-nowrap rounded-md bg-tertiary px-2.5 py-1.5 text-xs font-medium text-white opacity-0 shadow-lg transition-opacity duration-200 group-hover:opacity-100">
              I don't use this much
              <span className="absolute left-1/2 bottom-full -translate-x-1/2 -mb-1 w-2 h-2 rotate-45 bg-tertiary" />
            </span>
          </div>

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
