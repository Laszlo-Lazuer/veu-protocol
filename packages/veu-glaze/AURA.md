# veu-glaze: The Aura Aesthetic

The **Aura** Glaze is the default visual "mask" for the Veu protocol. It transforms encrypted data into a flowing, ethereal representation of the content's digital signature.

## 🎨 Visual Philosophy
Unlike a "blur," which is a lossy reduction of the original pixels, the **Aura** is a generative reconstruction.
- **The Glow:** Soft, shifting gradients that represent the "presence" of a post.
- **The Pulse:** A subtle animation keyed to the creation timestamp.
- **The Spectrum:** Colors are derived from the 256-bit **Glaze Seed** (HMAC-SHA-256).

## 🧬 Generative Logic (The Seed-to-Art Mapping)
The GLSL fragment shader uses the Glaze Seed as a source of entropy:
1. **Palette Derivation:** The first 64 bits of the seed define the 3 primary colors of the Aura.
2. **Flow Direction:** The next 32 bits determine the vector of the gradient movement.
3. **Density:** Bits 96-128 control the "fuzziness" or "sharpness" of the Aura's edges.

## 💻 Shader Specification (GLSL/Metal)
The Aura is rendered in real-time on the iPhone's GPU using a multi-pass fragment shader.
- **Pass 1:** Noise generation (Simplex/Perlin) based on the Glaze Seed.
- **Pass 2:** Color mapping via a trigonometric palette function.
- **Pass 3:** Temporal oscillation (the "Pulse").

## 🪞 The Double Mirror Effect
- **To the Public:** A beautiful, abstract animation that looks like a high-end digital art piece.
- **To the Circle:** Once the key is provided, the shader's opacity drops to 0, "lifting the Glaze" to reveal the underlying decrypted content.