# AI Preview - server fix (for the backend engineer)

**Problem seen in the app (Signage Design Studio, Order wizard, Power Supply):** the generated preview ignores the customer's design.
Example: design = Bebas Neue, ALL CAPS "ALIZA", Deep Blue letters with a blue glow, Silver Aluminium plate, 6 x 1.5 ft, navy wall.
AI output = lowercase text in another font, **yellow/golden backlight**, brick wall, wrong proportions.

**The app is already sending the right data.** It sends the guide fields `{ businessName, color, material, width, height, unit }` plus `font`, `style` (wall), `dimensions`, `background`, `notes` and `referenceImage` (a PNG render of the exact sign). The text is already sent in capitals for all-caps fonts. The cause is the server prompt, so the fix is server-side.

## What to change
1. In `server/customer/routes/customerRoutes.js` replace the `designPreview` schema with the block in section A (accepts the guide fields and the older ones).
2. In `server/customer/repositories/customerRepository.js` replace the whole `generateDesignPreview` function with section B.

What section B does:
- uses `color` for the letters **and** the LED glow ("never yellow, gold, orange or green unless that is the colour");
- uses `width` / `height` for the plate's width-to-height ratio;
- keeps the text exactly as sent; uses `font`, `background`/`material`, wall (`style`) and `notes`;
- if `referenceImage` is present and `OPENAI_API_KEY` is set, edits that render (gpt-image-1) so colours, glow, font, proportions and wall are preserved exactly - this is the most faithful path;
- returns `{ success, imageUrl, specifications }` (the app shows "AI used: ..." from `specifications`).

If your live version of `generateDesignPreview` differs, copy the prompt wording (colour/glow rule + ratio) and the `referenceImage` branch into it. Requires env: `OPENAI_API_KEY` (and Cloudinary vars if you want hosted URLs).

## A. Route schema (customerRoutes.js)
```js
// Guide fields: { businessName, color, material, width, height, unit }.
// Older fields (businessText, signType, background, dimensions...) are still accepted.
const designPreview = z
  .object({
    category: z.string().optional(),
    signType: z.string().optional(),
    businessName: z.string().trim().min(1).optional(),
    businessText: z.string().trim().min(1).optional(),
    font: z.string().optional(),
    color: z.string().optional(),
    material: z.string().optional(),
    background: z.string().optional(),
    style: z.string().optional(),
    width: z.coerce.number().positive().max(500).optional(),
    height: z.coerce.number().positive().max(500).optional(),
    unit: z.string().max(10).optional(),
    dimensions: z.string().optional(),
    notes: z.string().max(2000).optional(),
    lightingColor: z.string().optional(),
    glowColor: z.string().optional(),
    referenceImage: z.string().max(1_500_000).optional(),
  })
  .refine((v) => v.businessName || v.businessText, {
    message: "businessName is required",
    path: ["businessName"],
  });
```

## B. generateDesignPreview (customerRepository.js)
```js
async function generateDesignPreview(userId, input) {
  // Accepts the guide fields { businessName, color, material, width, height, unit }
  // and the older ones (businessText, background, dimensions...).
  const data = { ...input, businessText: input.businessName || input.businessText };
  const unit = input.unit || "ft";
  const w = Number(input.width);
  const h = Number(input.height);
  const hasSize = w > 0 && h > 0;
  if (!data.dimensions && hasSize) data.dimensions = `${w} x ${h} ${unit}`;
  if (!data.background && input.material) data.background = input.material;
  const ratioText = hasSize ? `${(w / h).toFixed(1)}:1` : "2:1";
  const specifications = {
    businessName: data.businessText,
    color: data.color || "Gold",
    material: data.background || undefined,
    width: hasSize ? w : undefined,
    height: hasSize ? h : undefined,
    unit,
  };
  const category = (data.category || data.signType || "Neon").toLowerCase();
  let prompt = "";
  if (category.includes("neon")) {
    prompt = `Create a photorealistic architectural interior photograph of a custom LED neon sign installed on a textured dark wall. The glowing sign reads exactly: "${data.businessText}". Neon Color: ${data.color || "Vibrant Neon Pink"}. Style: ${data.style || "Luminous contour"}. Clear acrylic cut-to-shape backing, soft ambient illumination, realistic reflections, 8k commercial quality concept render.`;
  } else if (category.includes("power") || category.includes("electrical")) {
    prompt = `Commercial product photography of an industrial LED signboard power supply unit, technical extruded aluminium casing with ventilation honeycomb holes, 12V DC terminals, specifications label, studio table lighting.`;
  } else {
    const fontLook = {
      montserrat: "bold geometric modern sans-serif capitals",
      "bebas neue": "tall condensed all-caps headline sans-serif",
      "playfair display": "elegant high-contrast luxury serif",
      outfit: "clean thin architectural geometric sans-serif",
      oswald: "narrow bold commercial gothic sans-serif",
    };
    const bgLook = {
      "glossy black acrylic": "a glossy jet-black acrylic panel with mirror-like reflections",
      "clear acrylic backing": "a transparent clear acrylic panel, glass-like, with the wall visible through it",
      "brushed gold acp": "a brushed gold metallic aluminium composite panel with fine linear grain",
      "silver aluminium panel": "a brushed silver aluminium panel with a metallic sheen",
      "architectural walnut wood": "a dark walnut wood panel with visible wood grain",
    };
    const wallLook = {
      "exposed dark brick": "an exposed dark brick wall",
      "industrial concrete": "a raw dark industrial concrete wall",
      "modern storefront": "a modern dark storefront facade",
      "luxury dark marble": "a luxury dark marble wall",
    };
    const fontName = String(data.font || "Montserrat").split(" (")[0];
    const fontDesc = fontLook[fontName.toLowerCase()] || "clean sans-serif";
    const bgName = String(data.background || "Brushed ACP aluminium");
    const bgDesc = bgLook[bgName.toLowerCase()] || bgName;
    const wallName = String(data.style || "").replace(/ wall$/i, "");
    const wallDesc = wallLook[wallName.toLowerCase()] || wallName || "a dark textured wall";
    const colorName = data.color || "Gold";
    prompt = `Photorealistic close-up photo of one illuminated 3D signboard fixed on ${wallDesc}, in a dark moody evening setting. The sign is a rectangular backing plate made of ${bgDesc}, with raised 3D letters mounted on the plate. The letters spell exactly "${data.businessText}" (no other words, no extra text, spelled correctly), in ${fontDesc} lettering (${fontName} typeface), colored ${colorName}, with a soft ${colorName} LED glow around the letters - the glow must be exactly ${colorName}, never yellow, gold, orange or green unless ${colorName} is that color. The plate is a rectangle whose width-to-height ratio is ${ratioText} (${data.dimensions || "3 x 1.5 ft"}), centered, front view, fully visible and not stretched. Do not use any other letter color, plate material, or wall.${data.notes ? ` ${String(data.notes).slice(0, 700)}` : ""}`;
  }
  // DALL-E 3 rewrites prompts by default; ask it to keep ours verbatim.
  prompt = `I NEED to test how the tool works with extremely simple prompts. DO NOT add any detail, just use it AS-IS: ${prompt}`;

  // Preferred path: the app sends a render of the exact sign the customer
  // configured; the model only makes it photorealistic, so every selection
  // (colors, font, plate, border, glow, wall) is preserved.
  if (process.env.OPENAI_API_KEY && data.referenceImage && !category.includes("power")) {
    try {
      const OpenAI = require("openai");
      const ai = require("../../services/aiPlatform");
      const raw = String(data.referenceImage).replace(/^data:image\/\w+;base64,/, "");
      const file = await OpenAI.toFile(Buffer.from(raw, "base64"), "sign-preview.png", { type: "image/png" });
      const editPrompt = `The attached image is the customer's exact signboard design mockup. Re-render it as a photorealistic photograph of that real sign installed on its wall. Preserve EXACTLY, without any change: the text "${data.businessText}" and its spelling; the lettering style and font shape; the letter color and the glow color; the backing plate color, material, rectangular shape, border and proportions; the wall color and texture; the overall composition and position. Do not add, remove or restyle anything, add no extra text, logos or objects, and do not change any color. Only add realism: real material texture, depth, lighting and a physical mounting.`;
      const result = await ai.openai().images.edit({
        model: process.env.OPENAI_IMAGE_EDIT_MODEL || "gpt-image-1",
        image: file,
        prompt: editPrompt,
        size: "1536x1024",
      });
      const b64 = result.data?.[0]?.b64_json;
      if (b64) {
        let imageUrl = `data:image/png;base64,${b64}`;
        if (process.env.CLOUDINARY_CLOUD_NAME) {
          try {
            const cloudinary = require("cloudinary").v2;
            cloudinary.config({
              cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
              api_key: process.env.CLOUDINARY_API_KEY,
              api_secret: process.env.CLOUDINARY_API_SECRET,
            });
            imageUrl = (
              await cloudinary.uploader.upload(imageUrl, { folder: "signfix/design-concepts" })
            ).secure_url;
          } catch (upErr) {
            console.warn("[AI] Cloudinary upload failed, returning inline image:", upErr.message);
          }
        }
        return {
          success: true,
          isRealAi: true,
          imageUrl,
          specifications,
          prompt: editPrompt,
          disclaimer: "Concept mockup only; not final production artwork.",
        };
      }
    } catch (editErr) {
      console.warn("[AI] Reference-image edit failed, falling back to text prompt:", editErr.message);
    }
  }

  if (process.env.OPENAI_API_KEY) {
    try {
      const ai = require("../../services/aiPlatform");
      const generated = await ai.generateDesign(prompt);
      let imageUrl = generated.url;
      if (generated.b64_json && process.env.CLOUDINARY_CLOUD_NAME) {
        const cloudinary = require("cloudinary").v2;
        cloudinary.config({
          cloud_name: process.env.CLOUDINARY_CLOUD_NAME,
          api_key: process.env.CLOUDINARY_API_KEY,
          api_secret: process.env.CLOUDINARY_API_SECRET,
        });
        imageUrl = (
          await cloudinary.uploader.upload(
            `data:image/png;base64,${generated.b64_json}`,
            { folder: "signfix/design-concepts" },
          )
        ).secure_url;
      }
      return {
        success: true,
        isRealAi: true,
        imageUrl,
        specifications,
        prompt,
        disclaimer: "Concept mockup only; not final production artwork.",
      };
    } catch (aiErr) {
      console.warn("[AI] Design generation failed, returning high-fidelity concept descriptor:", aiErr.message);
    }
  }

  return {
    success: true,
    isRealAi: false,
    apiKeyConfigured: Boolean(process.env.OPENAI_API_KEY),
    prompt,
    previewSpec: {
      text: data.businessText,
      font: data.font || "Montserrat",
      color: data.color || "#00E5FF",
      background: data.background || "acrylic_black",
      category: data.category || "signage",
      style: data.style || "modern",
      dimensions: data.dimensions || "3 × 1.5 ft",
    },
    disclaimer: "Deterministic concept rendered. For real DALL-E AI generation, set OPENAI_API_KEY in .env.",
  };
}
```