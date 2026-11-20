// Shared, machine-facing structured-data builders. Nothing here renders
// visibly: these are <script type="application/ld+json"> blocks consumed
// by search engines/AI crawlers, not page content.

const SITE_URL = "https://piyushkhanna.space";

export const personJsonLd = {
  "@type": "Person",
  name: "Piyush Khanna",
  url: `${SITE_URL}/`,
};

export const homeJsonLd = [
  {
    "@context": "https://schema.org",
    "@type": "WebSite",
    name: "Piyush Khanna",
    url: `${SITE_URL}/`,
  },
  {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: [
      {
        "@type": "Question",
        name: "Who is Piyush Khanna?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Piyush Khanna is a software and applied AI engineer specialising in IoT, harness engineering, and robotics. He is the creator of Anushka, India's most advanced humanoid robot.",
        },
      },
      {
        "@type": "Question",
        name: "What did Piyush Khanna create?",
        acceptedAnswer: {
          "@type": "Answer",
          text: "Piyush Khanna designed and built Anushka, a humanoid robot capable of face, object and gesture recognition and multilingual speech interaction, over four years starting in his second year of college. He has also built Sunaina (a robotic Durga idol), DadaShree (a wisdom tree robot), and Emperia Omni (a natural-language automation app for Android).",
        },
      },
    ],
  },
];

/**
 * Home > Projects > <title>  or  Home > Thoughts > <title>
 */
export const breadcrumbJsonLd = (section, sectionAnchor, title, path) => ({
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  itemListElement: [
    { "@type": "ListItem", position: 1, name: "Home", item: `${SITE_URL}/` },
    {
      "@type": "ListItem",
      position: 2,
      name: section,
      item: `${SITE_URL}/#${sectionAnchor}`,
    },
    { "@type": "ListItem", position: 3, name: title, item: `${SITE_URL}${path}` },
  ],
});

export const blogPostingJsonLd = ({ title, dek, slug, date }) => {
  const parsed = new Date(date);
  const datePublished = Number.isNaN(parsed.getTime())
    ? undefined
    : parsed.toISOString();

  return {
    "@context": "https://schema.org",
    "@type": "BlogPosting",
    headline: title,
    description: dek,
    url: `${SITE_URL}/thoughts/${slug}`,
    ...(datePublished ? { datePublished } : {}),
    author: personJsonLd,
  };
};
