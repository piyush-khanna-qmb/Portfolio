import React, { useRef, useState } from "react";
import { motion } from "framer-motion";
import emailjs from "@emailjs/browser";

import { styles } from "../styles";
import { EarthCanvas } from "./canvas";
import { SectionWrapper } from "../hoc";
import { slideIn } from "../utils/motion";

const Contact = () => {
  const formRef = useRef();
  const [form, setForm] = useState({
    name: "",
    email: "",
    message: "",
  });

  const [loading, setLoading] = useState(false);
  /* Inline status instead of alert(). alert() blocks every subsequent
     browser interaction and hides the real failure reason, which is why
     this form appeared to do nothing at all when the send failed. */
  const [status, setStatus] = useState(null); // { ok: boolean, text: string }

  const handleChange = (e) => {
    const { target } = e;
    const { name, value } = target;

    setForm({
      ...form,
      [name]: value,
    });
  };

  const handleSubmit = (e) => {
    e.preventDefault();

    const name = form.name.trim();
    const email = form.email.trim();
    const message = form.message.trim();

    if (!name || !email || !message) {
      setStatus({ ok: false, text: "Please fill in your name, email and message." });
      return;
    }

    setLoading(true);
    setStatus(null);

    emailjs
      .send(
        "service_um8nucw",
        "template_i612x8s",
        {
          from_name: name,
          to_name: "Piyush Khanna",
          /* The template reads {{from_mail}}. `from_email` is sent too so
             the form keeps working if the template is ever changed to the
             more conventional name. */
          from_mail: email,
          from_email: email,
          reply_to: email,
          to_email: "piyushkhannavb@gmail.com",
          message,
        },
        "2cuJ5paqCDI0a06Dg"
      )
      .then(
        () => {
          setLoading(false);
          setStatus({
            ok: true,
            text: "Thank you. I will get back to you as soon as possible.",
          });
          setForm({ name: "", email: "", message: "" });
        },
        (error) => {
          setLoading(false);
          console.error("EmailJS send failed:", error);
          /* Surface what the provider actually said. A silent failure here
             is worse than an ugly one. */
          const detail =
            (error && (error.text || error.message)) || "Unknown error";
          setStatus({
            ok: false,
            text: `Could not send: ${detail}. You can reach me directly at piyushkhannavb@gmail.com.`,
          });
        }
      );
  };

  return (
    <div
      className={`xl:mt-12 flex xl:flex-row flex-col-reverse gap-10 overflow-hidden`}
    >
      <motion.div
        variants={slideIn("left", "tween", 0.2, 1)}
        className='flex-[0.75] bg-black-100 p-8 rounded-2xl'
      >
        <p className={styles.sectionSubText}>Get in touch</p>
        <h3 className={styles.sectionHeadText}>Contact.</h3>

        <form
          ref={formRef}
          onSubmit={handleSubmit}
          className='mt-12 flex flex-col gap-8'
        >
          <label className='flex flex-col'>
            <span className='text-white font-medium mb-4'>Your Name</span>
            <input
              type='text'
              name='name'
              value={form.name}
              onChange={handleChange}
              placeholder="What's your good name?"
              className='bg-tertiary py-4 px-6 placeholder:text-secondary text-white rounded-lg outline-none border-none font-medium'
            />
          </label>
          <label className='flex flex-col'>
            <span className='text-white font-medium mb-4'>Your email</span>
            <input
              type='email'
              name='email'
              value={form.email}
              onChange={handleChange}
              placeholder="What's your web address?"
              className='bg-tertiary py-4 px-6 placeholder:text-secondary text-white rounded-lg outline-none border-none font-medium'
            />
          </label>
          <label className='flex flex-col'>
            <span className='text-white font-medium mb-4'>Your Message</span>
            <textarea
              rows={7}
              name='message'
              value={form.message}
              onChange={handleChange}
              placeholder='What do you want to say?'
              className='bg-tertiary py-4 px-6 placeholder:text-secondary text-white rounded-lg outline-none border-none font-medium'
            />
          </label>

          <button
            type='submit'
            disabled={loading}
            className='bg-tertiary py-3 px-8 rounded-xl outline-none w-fit text-white font-bold shadow-md shadow-primary disabled:opacity-60'
          >
            {loading ? "Sending..." : "Send"}
          </button>

          {status && (
            <p
              role='status'
              className={`text-[14px] leading-[22px] ${
                status.ok ? "text-[#5de0a0]" : "text-[#ff8a8a]"
              }`}
            >
              {status.text}
            </p>
          )}
        </form>
      </motion.div>

      <motion.div
        variants={slideIn("right", "tween", 0.2, 1)}
        className='xl:flex-1 xl:h-auto md:h-[550px] h-[350px]'
      >
        <EarthCanvas />
      </motion.div>
    </div>
  );
};

export default SectionWrapper(Contact, "contact");
