import React from "react";
import Tilt from "react-tilt";
import { Link } from "react-router-dom";
import { motion } from "framer-motion";

import { styles } from "../styles";
import { github } from "../assets";
import { linkedin } from "../assets";
import { SectionWrapper } from "../hoc";
import { projects } from "../constants";
import { fadeIn, textVariant } from "../utils/motion";

/**
 * Wraps the clickable body of a card. Projects without a dedicated
 * destination stay inert rather than rendering a dead link.
 */
const CardLink = ({ to, external, children, className }) => {
  if (!to) return <div className={className}>{children}</div>;

  if (external) {
    return (
      <a
        href={to}
        target='_blank'
        rel='noopener noreferrer'
        className={className}
      >
        {children}
      </a>
    );
  }

  return (
    <Link to={to} className={className}>
      {children}
    </Link>
  );
};

/* Stand-in for projects that do not have artwork yet. Keeps the grid
   even instead of collapsing the card height to nothing. */
const ImagePlaceholder = ({ name }) => (
  <div className='w-full h-full rounded-2xl flex items-center justify-center bg-gradient-to-br from-[#2a1f4d] via-[#1d1836] to-[#120f26]'>
    <span className='text-[#915EFF]/70 text-[44px] font-black'>
      {name.charAt(0)}
    </span>
  </div>
);

const ProjectCard = ({
  index,
  name,
  description,
  tags,
  image,
  source_code_link,
  linked_link,
  project_link,
  project_link_external,
}) => {
  return (
    <motion.div variants={fadeIn("up", "spring", index * 0.5, 0.75)}>
      <Tilt
        options={{
          max: 45,
          scale: 1,
          speed: 450,
        }}
        className='bg-tertiary p-5 rounded-2xl sm:w-[360px] w-full h-full flex flex-col'
      >
        <div className='relative w-full h-[230px]'>
          <CardLink
            to={project_link}
            external={project_link_external}
            className={`block w-full h-full rounded-2xl overflow-hidden ${
              project_link ? "cursor-pointer group" : ""
            }`}
          >
            {image ? (
              <img
                src={image}
                alt={name}
                className='w-full h-full object-cover rounded-2xl transition-transform duration-500 group-hover:scale-[1.04]'
              />
            ) : (
              <ImagePlaceholder name={name} />
            )}

            {project_link && (
              <span className='absolute inset-0 rounded-2xl bg-black/0 group-hover:bg-black/35 transition-colors duration-300 flex items-center justify-center'>
                <span className='opacity-0 group-hover:opacity-100 transition-opacity duration-300 text-white text-[13px] font-semibold bg-[#915EFF]/80 px-4 py-2 rounded-lg'>
                  View project
                </span>
              </span>
            )}
          </CardLink>

          <div className='absolute inset-0 flex justify-end gap-3 m-3 pointer-events-none'>
            {source_code_link && (
              <div
                onClick={() => window.open(source_code_link, "_blank")}
                className='pointer-events-auto black-gradient w-10 h-10 rounded-full flex justify-center items-center cursor-pointer'
              >
                <img
                  src={github}
                  alt='source code'
                  className='w-1/2 h-1/2 object-contain'
                />
              </div>
            )}
            {linked_link && (
              <div
                onClick={() => window.open(linked_link, "_blank")}
                className='pointer-events-auto black-gradient w-10 h-10 rounded-full flex justify-center items-center cursor-pointer'
              >
                <img
                  src={linkedin}
                  alt='linkedin post'
                  className='w-1/2 h-1/2 object-contain'
                />
              </div>
            )}
          </div>
        </div>

        <div className='mt-5'>
          <CardLink
            to={project_link}
            external={project_link_external}
            className={project_link ? "group" : ""}
          >
            <h3
              className={`text-white font-bold text-[24px] ${
                project_link
                  ? "group-hover:text-[#915EFF] transition-colors duration-300"
                  : ""
              }`}
            >
              {name}
            </h3>
          </CardLink>
          <p className='mt-2 text-secondary text-[14px]'>{description}</p>
        </div>

        <div className='mt-4 flex flex-wrap gap-2'>
          {tags.map((tag) => (
            <p key={`${name}-${tag.name}`} className={`text-[14px] ${tag.color}`}>
              #{tag.name}
            </p>
          ))}
        </div>
      </Tilt>
    </motion.div>
  );
};

const Works = () => {
  return (
    <>
      <motion.div variants={textVariant()}>
        <p className={`${styles.sectionSubText} `}>My work</p>
        <h2 className={`${styles.sectionHeadText}`}>Projects.</h2>
      </motion.div>

      <div className='w-full flex'>
        <motion.p
          variants={fadeIn("", "", 0.1, 1)}
          className='mt-3 text-secondary text-[17px] max-w-3xl leading-[30px]'
        >
          Following projects showcases my skills and experience through
          real-world examples of my work. Each project is briefly described with
          links to code repositories and live demos in it. It reflects my
          ability to solve complex problems, work with different technologies,
          and manage projects effectively.
        </motion.p>
      </div>

      <div className='mt-20 flex flex-wrap gap-7'>
        {projects.map((project, index) => (
          <ProjectCard key={`project-${index}`} index={index} {...project} />
        ))}
      </div>
    </>
  );
};

export default SectionWrapper(Works, "work");
