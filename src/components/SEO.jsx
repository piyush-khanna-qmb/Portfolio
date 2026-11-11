import { Helmet } from "react-helmet-async";

const SITE_URL = "https://piyushkhanna.space";
const DEFAULT_IMAGE = `${SITE_URL}/og-image.jpg`;

/**
 * Per-route title/description/OG/Twitter tags. `path` is the route's
 * path (e.g. "/project/omni") so canonical/og:url stay correct without
 * each page having to know the full domain.
 */
const SEO = ({
  title,
  description,
  path = "/",
  image = DEFAULT_IMAGE,
  imageAlt,
  jsonLd,
}) => {
  const url = `${SITE_URL}${path}`;
  const fullTitle = path === "/" ? title : `${title} | Piyush Khanna`;
  const jsonLdBlocks = jsonLd ? (Array.isArray(jsonLd) ? jsonLd : [jsonLd]) : [];

  return (
    <Helmet>
      <title>{fullTitle}</title>
      <meta name="description" content={description} />
      <link rel="canonical" href={url} />

      <meta property="og:type" content="website" />
      <meta property="og:site_name" content="Piyush Khanna" />
      <meta property="og:title" content={fullTitle} />
      <meta property="og:description" content={description} />
      <meta property="og:url" content={url} />
      <meta property="og:image" content={image} />
      <meta property="og:image:width" content="1200" />
      <meta property="og:image:height" content="630" />
      {imageAlt && <meta property="og:image:alt" content={imageAlt} />}

      <meta name="twitter:card" content="summary_large_image" />
      <meta name="twitter:title" content={fullTitle} />
      <meta name="twitter:description" content={description} />
      <meta name="twitter:image" content={image} />

      {jsonLdBlocks.map((block, i) => (
        <script key={i} type="application/ld+json">
          {JSON.stringify(block)}
        </script>
      ))}
    </Helmet>
  );
};

export default SEO;
