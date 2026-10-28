import {
  mobile,
  backend,
  creator,
  web,
  javascript,
  typescript,
  html,
  css,
  reactjs,
  redux,
  tailwind,
  nodejs,
  mongodb,
  git,
  docker,
  flutter,
  tpp,
  wipro,
  auto,
  mbs,
  fableroom,
  manojava,
  minerra,
  carrent,
  jobit,
  tripguide,
  threejs,
  android,
  ocv,
  unity,
  tf,
  ros,
  esp,
  rasp,
  java,
  py,
  anushka,
  tppi,
  brain,
  nfs,
  diary,
  bulk,
  AR,
  bin,
  opti,
  hodWala,
  mbsWala,
  tppWala,
  deanWala
} from "../assets";

export const navLinks = [
  {
    id: "work",
    title: "Work",
  },
  {
    id: "contact",
    title: "Contact",
  },
];

const services = [
  {
    title: "Full Stack Web Applications",
    icon: web,
  },
  {
    title: "Internet of Things",
    icon: mobile,
  },
  {
    title: "Robotics and Automation",
    icon: backend,
  },
  {
    title: "Augmented Reality",
    icon: creator,
  },
];

const technologies = [
  {
    name: "Java",
    icon: java,
  },
  {
    name: "Python",
    icon: py,
  },
  {
    name: "React JS",
    icon: reactjs,
  },
  {
    name: "Node JS",
    icon: nodejs,
  },
  {
    name: "MongoDB",
    icon: mongodb,
  },
  {
    name: "git",
    icon: git,
  },
  {
    name: "Tensorflow",
    icon: tf,
  },
  {
    name: "ROS",
    icon: ros,
  },
  {
    name: "Flutter",
    icon: flutter,
  },
  {
    name: "Android",
    icon: android,
  },
  {
    name: "Docker",
    icon: docker,
  },
  {
    name: "OpenCV",
    icon: ocv,
  },
  {
    name: "Unity",
    icon: unity,
  },
];

const experiences = [
  {
    title: "Research Intern",
    company_name: "MBS India",
    icon: mbs,
    iconBg: "#E6DEDD",
    date: "May 2021 - July 2021",
    points: [
      "Reinforced and enhanced the design of Oxyana - Oxygen Concentrator for Soldiers, a patented product of MBS India.",
      "Researched applying Machine Learning to filter noisy signals in heartbeat and pulse forms, and engineered a design for a smart stethoscope using the same technology.",
    ],
  },
  {
    title: "Backend Developer",
    company_name: "Manojava Software India",
    location: "Noida (Sec-63), India",
    icon: manojava,
    iconFill: true,
    iconBg: "#29abe2",
    date: "Jan 2024 - Apr 2025",
    points: [
      "Designed and built scalable RESTful APIs with Node.js and Express.js — documented in Swagger, end-to-end tested in Postman, and backed by a MongoDB layer tuned through Mongoose for production query performance.",
      "Acted as System Architect, translating the founders' concept into a structured, scalable technical roadmap and development plan.",
    ],
  },
  {
    title: "FullStack Developer",
    company_name: "Minerra Health",
    location: "Remote (US)",
    icon: minerra,
    iconBg: "#ffffff",
    date: "Apr 2025 - July 2026",
    points: [
      "Developed and maintained scalable backend services in Python (Django & DRF), implementing secure, modular and reusable RESTful APIs consumed across web and mobile clients.",
      "Implemented JWT-based authentication and role-based access control for HIPAA-compliant data handling, and deployed the services on AWS EC2 with automated GitHub Actions CI/CD pipelines.",
    ],
  },
  {
    title: "Forward Deployed Engineer",
    company_name: "Fableroom",
    location: "DLF Golf Course, Gurgaon",
    icon: fableroom,
    iconFill: true,
    iconBg: "#9c6a14",
    date: "July 2026 - Present",
    points: [
      "Integrating logistics solutions into the company's in-house tooling, wiring third-party delivery and fulfilment workflows into systems built and owned internally.",
      "Working across a Python stack on AWS, with the customer-facing frontend built on Alpine.js.",
    ],
  },
];

const testimonials = [
  // {
  //   testimonial:
  //     "Piyush is a very honest and humble boy with extraordinary skillset and diligent mindset. He has already brought many laurels to us and the KIET family and I wish him all the luck for his future endeavours.",
  //   name: "Dr. Ajay Kr. Srivastava",
  //   designation: "HOD",
  //   company: "KIET CS",
  //   image: hodWala,
  // },
  {
    testimonial:
      "Piyush is a very honest and humble boy with extraordinary skillset and diligent mindset. He has already brought many laurels to us and the KIET family and I wish him all the luck for his future endeavours.",
    name: "Dr. Shubham Shukla",
    designation: "Dean",
    company: "KIET R&D",
    image: deanWala,
  },
  {
    testimonial:
      "We liked the work of Mr. Piyush very much. He was very cooperative during the entire process of site design and implementation and gave us creative ideas for the [User Interface] as well.",
    name: "Mr. Rasik Tiwari",
    designation: "CEO",
    company: "Teerth Purohit Prayagraj",
    image: tppWala,
  },
  {
    testimonial:
      "...We appreciate Mr. Piyush Khanna for his remarkable contribution for Oxyana: Oxygen Analyzer for Soldiers ©️. He is a dutiful person with a powerful skillset.",
    name: "Dr. Sundeep Rohilla",
    designation: "CEO",
    company: "MBS India",
    image: mbsWala,
  },

];

const projects = [
  {
    name: "Anushka",
    description:
      "Anushka is a groundbreaking humanoid robot that redefines human-robot interactions with its lifelike appearance, ability to recognize faces, objects, and gestures as well as understand and respond to human speech in multiple languages.",
    tags: [
      {
        name: "AI and ML",
        color: "blue-text-gradient",
      },
      {
        name: "Embed",
        color: "green-text-gradient",
      },
      {
        name: "MERN",
        color: "pink-text-gradient",
      },
      {
        name: "OS Design",
        color: "orange-text-gradient",
      },
    ],
    image: anushka,
    source_code_link: "https://anushkathehumanoid.com",
    linked_link: null,
    project_link: "https://anushkathehumanoid.com",
    project_link_external: true,
  },
  {
    name: "Sunaina Robot",
    description:
      "A robotic Durga that served as the presiding figure at Chakraberia Sarbojanin Durgotsab, Kolkata, during Durga Puja 2025. Articulated gaze, neck and hand movement, built to be looked at by lakhs of people rather than operated by any of them.",
    tags: [
      { name: "Robotics", color: "blue-text-gradient" },
      { name: "Animatronics", color: "green-text-gradient" },
      { name: "Embedded C", color: "pink-text-gradient" },
    ],
    image: null,
    source_code_link: null,
    linked_link: null,
    project_link: "/project/sunaina",
    project_link_external: false,
  },
  {
    name: "DadaShree Robot",
    description:
      "A humanoid named with a relational honorific rather than a personal name — 'respected elder brother'. The naming is the interface: an Indian visitor already knows how to approach a Dada without being told.",
    tags: [
      { name: "Robotics", color: "blue-text-gradient" },
      { name: "HRI", color: "green-text-gradient" },
      { name: "Embedded", color: "pink-text-gradient" },
    ],
    image: null,
    source_code_link: null,
    linked_link: null,
    project_link: "/project/dadashree",
    project_link_external: false,
  },
  {
    name: "Emperia Omni",
    description:
      "Part of the Emperia Automation Ecosystem — the IoT/home-automation platform built at Emperia Smart Solutions. Lives on the Emperia site alongside UniHub rather than here.",
    tags: [
      { name: "IoT", color: "blue-text-gradient" },
      { name: "Automation", color: "green-text-gradient" },
      { name: "Hardware", color: "pink-text-gradient" },
    ],
    image: null,
    source_code_link: null,
    linked_link: null,
    project_link: "https://emperiasmartsolutions.space",
    project_link_external: true,
  },
  {
    name: "GyrusGriham",
    description:
      "GyrusGriham is a Brain Controlled Home Automation System! An IoT project which employs MindWave headset to analyze brainwave signals and apply ML algorithms to estimate 'focus level' of the brain and trigger home automation appliances.",
    tags: [
      {
        name: "Android",
        color: "blue-text-gradient",
      },
      {
        name: "MERN",
        color: "green-text-gradient",
      },
      {
        name: "IoT",
        color: "pink-text-gradient",
      },
    ],
    image: brain,
    source_code_link: "https://github.com/piyush-khanna-qmb/Gyrus-Griham",
    linked_link: null
  },
  {
    name: "The Gamchha Diary",
    description:
      "The gamchha Diary is a MERN stack-powered blog website that offers fast and secure content retrieval while adding a personal touch with customizable themes and interactive elements. Effortlessly embed multimedia, and craft engaging narratives.",
    tags: [
      {
        name: "ReactJS",
        color: "blue-text-gradient",
      },
      {
        name: "MongoDB",
        color: "green-text-gradient",
      },
      {
        name: "ExpressJS",
        color: "pink-text-gradient",
      },
    ],
    image: diary,
    source_code_link: "https://github.com/piyush-khanna-qmb/Blog-Site",
    linked_link: null
  },
  {
    name: "SIGMA",
    description:
      "Synchronized Interface for Gaming Machine Augmentation is a gaming simulator made using set of actuators such as joystick, rotary encoders and embedded systems interfaced with PC using pyserial library for precise and accurate driving simulation.",
    tags: [
      {
        name: "Embedded C",
        color: "blue-text-gradient",
      },
      {
        name: "Python",
        color: "green-text-gradient",
      },
      {
        name: "Computer Vision",
        color: "pink-text-gradient",
      },
    ],
    image: nfs,
    source_code_link: "https://github.com/piyush-khanna-qmb/I-am-Speed",
    linked_link: null
  },
  {
    name: "Pigrazzi",
    description:
      "Pigrazzi introduces a paradigm shift in web media retrieval. It simplifies bulk image downloads while offering customization options for visuals, saving you precious time and fostering tech creativity at your fingertips.",
    tags: [
      {
        name: "GUI Automation",
        color: "blue-text-gradient",
      },
      {
        name: "Bash Curl",
        color: "green-text-gradient",
      },
      {
        name: "Python",
        color: "pink-text-gradient",
      },
    ],
    image: bulk,
    source_code_link: "https://github.com/piyush-khanna-qmb/Zucc-Snucc",
    linked_link: null
  },
  {
    name: "OptiTone",
    description:
      "OptiTone is a Computer Vision based volume controller for your PC. It lets you control your computer's audio system with simple hand gestures such as volume turn up/down, next/previous track, play/pause features with mapping from over 35 hand gestures.",
    tags: [
      {
        name: "OpenCV",
        color: "blue-text-gradient",
      },
      {
        name: "PyAutoGUI",
        color: "green-text-gradient",
      },
      {
        name: "PyCaw",
        color: "pink-text-gradient",
      },
    ],
    image: opti,
    source_code_link: "https://github.com/piyush-khanna-qmb/Hand-Volume-Control",
    linked_link: null
  },
  {
    name: "Teerth Purohit Prayagraj",
    description:
      "This simple portfolio project enhances marketing and customer interaction for the temple purohit. Created with WhatsApp, Instagram, maps, and email functionalities, it boosted their family profession's marketing and customer engagement significantly.",
    tags: [
      {
        name: "HTML",
        color: "blue-text-gradient",
      },
      {
        name: "CSS",
        color: "green-text-gradient",
      },
      {
        name: "Javascript",
        color: "pink-text-gradient",
      },
    ],
    image: tppi,
    source_code_link: "https://piyush-khanna-qmb.github.io/TeerthPurohitPrayagraj/",
    linked_link: null
  },

  {
    name: "AR4U",
    description:
      "AR_4_U, powered by Unity, revolutionizes Augmented Reality content creation. Import custom or library-based 3D models and let its advanced machine learning capabilities automatically suggest lifelike movements for various parts of your models.",
    tags: [
      {
        name: "Unity",
        color: "blue-text-gradient",
      },
      {
        name: "Vuforia",
        color: "green-text-gradient",
      },
      {
        name: "Machine Learning",
        color: "pink-text-gradient",
      },
    ],
    image: AR,
    source_code_link: "https://github.com/piyush-khanna-qmb/AR-4-U",
    linked_link: null
  },
  {
    name: "BinGenius",
    description:
      "BinGenius is your smart waste management companion. With its advanced sensors and AI-driven technology, BinMinder knows when it's full, compacts trash for more space, alerts the collection service when it's time for pickup and even helps you sort recyclables.",
    tags: [
      {
        name: "IoT",
        color: "blue-text-gradient",
      },
      {
        name: "Embedded C",
        color: "green-text-gradient",
      },
      {
        name: "Bash",
        color: "pink-text-gradient",
      },
    ],
    image: bin,
    source_code_link: "https://github.com/piyush-khanna-qmb/Koodha-Daan",
    linked_link: null
  },
];

export { services, technologies, experiences, testimonials, projects };
export {
  pressReleases,
  pressSocial,
  publications,
  certificates,
  galleryPhotos,
} from "./content";
export { thoughts } from "./thoughts";
