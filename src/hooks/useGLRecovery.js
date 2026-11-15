import { useCallback, useState } from "react";

/**
 * Phones evict WebGL contexts under memory pressure, and a lost context
 * never comes back on its own unless something calls preventDefault() on
 * the loss event. Rather than manually re-uploading every lost GPU
 * resource, bump a key to force React (and r3f) to tear the canvas down
 * and build a fresh context from scratch — cheap, since loaders cache
 * already-fetched assets.
 */
const useGLRecovery = () => {
  const [key, setKey] = useState(0);

  const onCreated = useCallback(({ gl }) => {
    const canvas = gl.domElement;
    const handleContextLost = (event) => {
      event.preventDefault();
      setKey((k) => k + 1);
    };
    canvas.addEventListener("webglcontextlost", handleContextLost, {
      once: true,
    });
  }, []);

  return { glKey: key, onCreated };
};

export default useGLRecovery;
