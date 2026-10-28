import React from "react";
import { useParams, Link, Navigate } from "react-router-dom";

import { thoughts } from "../constants";
import PageShell from "./PageShell";

const Block = ({ block }) => {
  switch (block.type) {
    case "h":
      return (
        <h2 className='text-white font-bold text-[22px] sm:text-[26px] leading-[34px] mt-12 mb-1'>
          {block.text}
        </h2>
      );

    case "quote":
      return (
        <blockquote className='my-9 border-l-2 border-[#915EFF] pl-6 text-white text-[19px] sm:text-[21px] leading-[33px] font-medium'>
          {block.text}
        </blockquote>
      );

    case "list":
      return (
        <ul className='my-6 flex flex-col gap-3'>
          {block.items.map((item, i) => (
            <li key={i} className='flex gap-3 text-secondary text-[17px] leading-[30px]'>
              <span aria-hidden='true' className='text-[#915EFF] shrink-0 mt-[2px]'>
                &#8226;
              </span>
              <span>{item}</span>
            </li>
          ))}
        </ul>
      );

    case "p":
    default:
      return (
        <p className='text-secondary text-[17px] leading-[32px] mt-5'>
          {block.text}
        </p>
      );
  }
};

const ThoughtPost = () => {
  const { slug } = useParams();
  const index = thoughts.findIndex((post) => post.slug === slug);

  if (index === -1) return <Navigate to='/' replace />;

  const post = thoughts[index];
  const next = thoughts[(index + 1) % thoughts.length];

  return (
    <PageShell
      eyebrow={`${post.date} · ${post.readingTime} read`}
      title={post.title}
      intro={post.dek}
    >
      <article className='max-w-3xl'>
        {post.body.map((block, i) => (
          <Block key={i} block={block} />
        ))}
      </article>

      {next && next.slug !== post.slug && (
        <div className='max-w-3xl mt-20 pt-8 border-t border-white/10'>
          <p className='text-secondary text-[13px] uppercase tracking-wider'>
            Read next
          </p>
          <Link
            to={`/thoughts/${next.slug}`}
            className='group mt-3 block focus:outline-none focus-visible:ring-2 focus-visible:ring-[#915EFF] rounded-sm'
          >
            <h3 className='text-white font-bold text-[20px] sm:text-[23px] leading-[31px] group-hover:text-[#915EFF] transition-colors duration-300'>
              {next.title}
            </h3>
            <p className='mt-2 text-secondary text-[15px] leading-[26px]'>
              {next.dek}
            </p>
          </Link>
        </div>
      )}
    </PageShell>
  );
};

export default ThoughtPost;
