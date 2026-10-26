"""Turn one photo into a SketchUp-ready mesh.

Engines: Hunyuan3D-2 mini and TripoSR run on this PC; Meshy runs online with
the user's own API key (passed in the PHOTOTO3D_MESHY_KEY environment variable).

Called by the SketchUp extension. Writes a JSON file with vertices, triangles
and either a small color palette or (Meshy) UVs plus a texture image, which the
extension turns into SketchUp faces.
"""

import argparse
import json
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
# The script ships inside the SketchUp extension; the AI itself is installed here.
HOME = os.environ.get("PHOTOTO3D_HOME") or os.path.join(os.environ["LOCALAPPDATA"], "PhotoTo3D")

# The shim folder provides torchmcubes, which can't be installed on Windows
# without a CUDA compiler. The AI engines' own source lives next to the backend.
sys.path.insert(0, os.path.join(HERE, "shim"))
sys.path.insert(0, os.path.join(HOME, "TripoSR"))
sys.path.insert(0, os.path.join(HOME, "Hunyuan3D-2"))

# Keep every downloaded AI file inside the PhotoTo3D folder.
os.environ.setdefault("HF_HOME", os.path.join(HOME, "cache", "huggingface"))
os.environ.setdefault("HY3DGEN_MODELS", os.path.join(HOME, "cache", "hy3dgen"))
os.environ.setdefault("U2NET_HOME", os.path.join(HOME, "cache", "rembg"))

ENGINES = ("hunyuan", "triposr", "meshy")
STEPS = 5


class Status:
    """Writes "step|total|message" to a file the extension shows in SketchUp."""

    def __init__(self, path):
        self.path = path

    def __call__(self, step, message):
        print(message, flush=True)
        if self.path:
            with open(self.path, "w", encoding="utf-8") as f:
                f.write(f"{step}|{STEPS}|{message}")


def load_hunyuan():
    import torch
    from hy3dgen.shapegen import Hunyuan3DDiTFlowMatchingPipeline

    if not torch.cuda.is_available():
        raise RuntimeError("Hunyuan3D 需要 NVIDIA 顯示卡。請改用 TripoSR。")
    pipeline = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained(
        "tencent/Hunyuan3D-2mini",
        subfolder="hunyuan3d-dit-v2-mini-turbo",
        use_safetensors=False,
        device="cuda",
    )
    pipeline.enable_flashvdm(topk_mode="merge")
    return pipeline


def download_delight():
    from huggingface_hub import snapshot_download

    # A plain folder instead of the Hugging Face cache, whose links need
    # Windows Developer Mode and can fail part way through.
    folder = os.path.join(HOME, "cache", "delight")
    snapshot_download("tencent/Hunyuan3D-2", allow_patterns=["hunyuan3d-delight-v2-0/*"], local_dir=folder)
    return os.path.join(folder, "hunyuan3d-delight-v2-0")


def load_delight():
    """Hunyuan3D's light remover: repaints a photo without highlights, shadows or colored light."""
    import torch
    from diffusers import EulerAncestralDiscreteScheduler, StableDiffusionInstructPix2PixPipeline

    pipeline = StableDiffusionInstructPix2PixPipeline.from_pretrained(
        download_delight(), torch_dtype=torch.float16, safety_checker=None
    )
    pipeline.scheduler = EulerAncestralDiscreteScheduler.from_config(pipeline.scheduler.config)
    pipeline.set_progress_bar_config(disable=True)
    return pipeline.to("cuda")


def remove_lighting(cutout):
    """Returns the cut-out photo with the lighting taken out, keeping its transparency.

    Without this, yellow lamp light, glare and shadows in the photo get painted
    onto the model as if they were the object's own colors.
    """
    import numpy as np
    import torch
    from PIL import Image

    rgba = np.asarray(cutout.convert("RGBA"))
    alpha = rgba[:, :, 3:4] / 255.0
    # The light remover was trained on objects on a white background.
    on_white = (rgba[:, :, :3] * alpha + 255 * (1 - alpha)).astype(np.uint8)
    small = Image.fromarray(on_white).resize((512, 512), Image.LANCZOS)

    pipeline = load_delight()
    with torch.no_grad():
        flat = pipeline(
            prompt="",
            image=small,
            height=512,
            width=512,
            num_inference_steps=50,
            image_guidance_scale=1.5,
            guidance_scale=1.0,
            generator=torch.manual_seed(42),
        ).images[0]
    del pipeline
    torch.cuda.empty_cache()

    flat = np.asarray(flat.resize(cutout.size, Image.LANCZOS)).astype(np.float32)
    flat = match_colors(flat, on_white.astype(np.float32), rgba[:, :, 3] > 127)
    return Image.fromarray(np.dstack([flat, rgba[:, :, 3]]), "RGBA")


def match_colors(flat, photo, mask):
    """Bring the overall colors back to the photo's.

    The light remover also shifts colors (red gets redder, white goes beige).
    Matching each channel's average and spread to the photo keeps the photo's
    colors while the glare and glow stay removed. Same as Hunyuan3D's own fix.
    """
    import numpy as np

    matched = np.empty_like(flat)
    for c in range(3):
        src, dst = flat[:, :, c][mask], photo[:, :, c][mask]
        spread = dst.std() / max(src.std(), 1e-3)
        matched[:, :, c] = (flat[:, :, c] - 0.95 * src.mean()) * spread + 0.95 * dst.mean()
    matched = np.clip(matched, 0, 255)
    # Keep the plain result when matching would move it further from the photo.
    if ((flat - photo)[mask] ** 2).mean() < ((matched - photo)[mask] ** 2).mean():
        matched = flat
    return matched.astype(np.uint8)


def load_triposr(device):
    from tsr.system import TSR

    model = TSR.from_pretrained(
        "stabilityai/TripoSR", config_name="config.yaml", weight_name="model.ckpt"
    )
    model.renderer.set_chunk_size(8192)
    model.to(device)
    return model


def cut_out(path, keep_background, session):
    """Returns the photo as RGBA with the background made transparent."""
    from PIL import Image, ImageOps
    from tsr.utils import remove_background, resize_foreground

    image = ImageOps.exif_transpose(Image.open(path))

    if keep_background:
        image = image.convert("RGB")
        side = max(image.size)
        square = Image.new("RGBA", (side, side), (127, 127, 127, 255))
        square.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
        return square

    # A PNG that is already cut out keeps its own transparency.
    if image.mode != "RGBA":
        image = image.convert("RGB")
    image = remove_background(image, session)
    return resize_foreground(image, 0.85)


def on_gray(cutout):
    """TripoSR expects the object on a plain gray background."""
    import numpy as np
    from PIL import Image

    pixels = np.array(cutout.convert("RGBA")).astype(np.float32) / 255.0
    alpha = pixels[:, :, 3:4]
    pixels = pixels[:, :, :3] * alpha + (1 - alpha) * 0.5
    return Image.fromarray((pixels * 255.0).astype(np.uint8))


def make_hunyuan(pipeline, cutout):
    import torch

    with torch.no_grad():
        return pipeline(
            image=cutout,
            num_inference_steps=5,
            octree_resolution=380,
            num_chunks=20000,
            generator=torch.manual_seed(12345),
            output_type="trimesh",
        )[0]


def make_triposr(model, cutout, device, resolution):
    import torch

    with torch.no_grad():
        scene_codes = model([on_gray(cutout)], device=device)
    return model.extract_mesh(scene_codes, True, resolution=resolution)[0]


def drop_floating_bits(mesh):
    """Remove small loose pieces that the AI sometimes leaves around the object."""
    import trimesh

    parts = mesh.split(only_watertight=False)
    if len(parts) <= 1:
        return mesh
    biggest = max(len(p.faces) for p in parts)
    kept = [p for p in parts if len(p.faces) >= biggest * 0.02]
    return trimesh.util.concatenate(kept)


def simplify(mesh, target_faces):
    """Reduce the triangle count so SketchUp stays fast, keeping any colors."""
    import fast_simplification
    import numpy as np
    import trimesh
    from scipy.spatial import cKDTree

    if len(mesh.faces) <= target_faces:
        return mesh

    reduction = 1.0 - target_faces / len(mesh.faces)
    vertices, faces = fast_simplification.simplify(
        np.asarray(mesh.vertices, dtype=np.float32),
        np.asarray(mesh.faces, dtype=np.int64),
        target_reduction=reduction,
    )
    if mesh.visual.kind != "vertex":
        return trimesh.Trimesh(vertices=vertices, faces=faces)

    # Simplifying loses vertex colors, so copy each one from the nearest original vertex.
    _, nearest = cKDTree(mesh.vertices).query(vertices)
    colors = np.asarray(mesh.visual.vertex_colors)[nearest]
    return trimesh.Trimesh(vertices=vertices, faces=faces, vertex_colors=colors)


def to_sketchup_space(mesh, engine):
    """Turn the model so its front faces SketchUp's Front view, stand it on the ground, height 1."""
    import numpy as np
    import trimesh

    if engine == "triposr":
        # TripoSR is Z-up with the front facing +X.
        turn = trimesh.transformations.rotation_matrix(-np.pi / 2, [0, 0, 1])
    else:
        # Hunyuan3D and Meshy's glTF are Y-up with the front facing +Z.
        turn = trimesh.transformations.rotation_matrix(np.pi / 2, [1, 0, 0])
    mesh.apply_transform(turn)

    lo, hi = mesh.bounds
    size = hi - lo
    height = size[2] if size[2] > 1e-6 else size.max()
    center = (lo + hi) / 2
    mesh.apply_translation([-center[0], -center[1], -lo[2]])
    mesh.apply_scale(1.0 / height)
    return mesh


def paint_from_photo(mesh, cutout):
    """Color the model with the photo as seen from the front.

    Parts the camera could see take the photo's color. Hidden parts (the back,
    under-sides) copy the color of the nearest visible part.
    """
    import numpy as np
    import trimesh
    from scipy.ndimage import binary_erosion
    from scipy.spatial import cKDTree

    rgba = np.asarray(cutout.convert("RGBA"))
    mask = rgba[:, :, 3] > 127
    rows, cols = np.nonzero(mask)
    if len(rows) == 0:
        raise RuntimeError("張相搵唔到物件。試下用清楚啲、得一件嘢嘅相。")
    top, bottom, left, right = rows.min(), rows.max(), cols.min(), cols.max()

    # Front view looks from -Y: photo x follows model X, photo up follows model Z.
    lo, hi = mesh.bounds
    span = np.maximum(hi - lo, 1e-6)

    def to_photo(points):
        u = left + (points[:, 0] - lo[0]) / span[0] * (right - left)
        v = bottom - (points[:, 2] - lo[2]) / span[2] * (bottom - top)
        return np.clip(np.rint(u).astype(int), 0, rgba.shape[1] - 1), np.clip(np.rint(v).astype(int), 0, rgba.shape[0] - 1)

    # Depth buffer from many surface points, to know which vertices the camera sees.
    grid = 256
    def cell(points):
        gx = np.clip(((points[:, 0] - lo[0]) / span[0] * (grid - 1)).astype(int), 0, grid - 1)
        gz = np.clip(((points[:, 2] - lo[2]) / span[2] * (grid - 1)).astype(int), 0, grid - 1)
        return gz * grid + gx

    samples, _ = trimesh.sample.sample_surface(mesh, 400000)
    nearest_depth = np.full(grid * grid, np.inf)
    np.minimum.at(nearest_depth, cell(samples), samples[:, 1])

    vertices = np.asarray(mesh.vertices)
    tolerance = span[1] * 0.02
    seen = vertices[:, 1] <= nearest_depth[cell(vertices)] + tolerance
    seen &= np.asarray(mesh.vertex_normals)[:, 1] < -0.3  # facing the camera, not edge-on
    # Skip the photo's outline, where the cut-out edge has dark or background pixels.
    inner = binary_erosion(mask, iterations=max(1, (bottom - top) // 60))
    u, v = to_photo(vertices)
    seen &= inner[v, u]

    colors = np.zeros((len(vertices), 4), dtype=np.uint8)
    colors[:, 3] = 255
    colors[seen, :3] = rgba[v[seen], u[seen], :3]
    if seen.any() and not seen.all():
        _, nearest = cKDTree(vertices[seen]).query(vertices[~seen])
        colors[~seen, :3] = colors[seen][nearest, :3]
    elif not seen.any():
        colors[:, :3] = rgba[mask][:, :3].mean(axis=0)
    mesh.visual.vertex_colors = colors
    return mesh


def palette_colors(mesh, count):
    """Give each triangle one of `count` colors, since SketchUp faces have one material."""
    import numpy as np
    from PIL import Image

    vertex_colors = np.asarray(mesh.visual.vertex_colors)[:, :3].astype(np.float32)
    face_colors = vertex_colors[mesh.faces].mean(axis=1).astype(np.uint8)

    if count <= 1:
        average = face_colors.mean(axis=0).astype(int).tolist()
        return [0] * len(face_colors), [average]

    strip = Image.fromarray(face_colors.reshape(1, -1, 3))
    quantized = strip.quantize(colors=count, method=Image.Quantize.MEDIANCUT)
    indices = np.array(quantized).reshape(-1)
    full_palette = np.array(quantized.getpalette()[: 3 * 256]).reshape(-1, 3)

    used, compact = np.unique(indices, return_inverse=True)
    return compact.tolist(), full_palette[used].tolist()


MESHY_API = "https://api.meshy.ai/openapi/v1/image-to-3d"
MESHY_ERRORS = {
    400: "Meshy 唔接受呢張相（格式、大細或者內容有問題）。",
    401: "Meshy API key 唔啱。請喺視窗重新輸入。",
    402: "Meshy 戶口 credits 唔夠，或者係免費計劃（用 API 要付費計劃）。",
    429: "Meshy 而家太多人用，請等一陣再試。",
}


def meshy_request(method, url, key, body=None):
    import urllib.error
    import urllib.request

    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        message = MESHY_ERRORS.get(error.code, f"Meshy 出錯（{error.code}）。")
        raise RuntimeError(f"{message}\n{detail}") from None
    except urllib.error.URLError as error:
        raise RuntimeError(f"連唔到 Meshy，請檢查網絡。（{error.reason}）") from None


def make_meshy(cutout, faces, job_dir, status):
    """Sends the photo to Meshy's online AI and downloads the textured model."""
    import base64
    import io
    import time
    import urllib.request

    import trimesh

    key = os.environ.get("PHOTOTO3D_MESHY_KEY", "").strip()
    if not key:
        raise RuntimeError("未輸入 Meshy API key。")

    image = cutout.copy()
    image.thumbnail((2048, 2048))
    buffer = io.BytesIO()
    image.save(buffer, "PNG")
    task = meshy_request("POST", MESHY_API, key, {
        "image_url": "data:image/png;base64," + base64.b64encode(buffer.getvalue()).decode("ascii"),
        "ai_model": "latest",
        "should_texture": True,
        "texture_resolution": "2k",
        "should_remesh": True,
        "topology": "triangle",
        "target_polycount": max(100, min(faces, 300000)),
        "target_formats": ["glb"],
    })["result"]

    deadline = time.time() + 20 * 60
    while True:
        info = meshy_request("GET", f"{MESHY_API}/{task}", key)
        state = info.get("status")
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELED"):
            reason = (info.get("task_error") or {}).get("message") or state
            raise RuntimeError(f"Meshy 整唔到模型：{reason}")
        if time.time() > deadline:
            raise RuntimeError("Meshy 等咗 20 分鐘都未完成，請遲啲再試。")
        if state == "PENDING":
            status(3, f"Meshy 雲端排緊隊（前面仲有 {info.get('preceding_tasks', '?')} 個）")
        else:
            status(3, f"Meshy 雲端生成緊 {info.get('progress', 0)}%")
        time.sleep(5)

    status(4, "下載模型同貼圖")
    glb = os.path.join(job_dir, "meshy.glb")
    urllib.request.urlretrieve(info["model_urls"]["glb"], glb)
    return trimesh.load(glb, force="mesh")


def textured_result(mesh, job_dir):
    """Keeps the model's real texture: per-vertex UVs plus the texture image."""
    material = getattr(mesh.visual, "material", None)
    image = getattr(material, "baseColorTexture", None) or getattr(material, "image", None)
    uv = getattr(mesh.visual, "uv", None)
    if image is None or uv is None:
        raise RuntimeError("下載咗嘅模型冇貼圖。")

    texture = os.path.join(job_dir, "texture.png")
    image.convert("RGB").save(texture)
    return {
        "vertices": [[round(float(c), 5) for c in v] for v in mesh.vertices],
        "faces": mesh.faces.tolist(),
        "uvs": [[round(float(u), 5), round(float(v), 5)] for u, v in uv],
        "texture": texture,
    }


def write_result(path, result):
    temp = path + ".tmp"
    with open(temp, "w", encoding="utf-8") as f:
        json.dump(result, f)
    os.replace(temp, path)


def run(args, status):
    status(1, "準備緊（第一次會慢少少）")
    import rembg
    import torch

    device = "cuda:0" if torch.cuda.is_available() and not args.cpu else "cpu"
    session = rembg.new_session()

    if args.download_only:
        load_triposr(device)
        if torch.cuda.is_available():
            load_hunyuan()
            download_delight()
        status(STEPS, f"AI files are ready. Using: {device}")
        return

    if args.engine == "meshy":
        status(2, "將物件由相片剪出嚟")
        cutout = cut_out(args.image, args.keep_background, session)
        status(3, "上載相片去 Meshy 雲端")
        mesh = make_meshy(cutout, args.faces, os.path.dirname(os.path.abspath(args.out)), status)
        mesh = to_sketchup_space(mesh, args.engine)
        write_result(args.out, textured_result(mesh, os.path.dirname(os.path.abspath(args.out))))
        status(STEPS, f"完成：{len(mesh.faces)} 個面")
        return

    status(2, "將物件由相片剪出嚟")
    cutout = cut_out(args.image, args.keep_background, session)

    # The colors come from a copy of the photo without its lighting. Hunyuan3D
    # still builds the shape from the real photo, whose shading shows the form.
    colors_from = cutout
    if args.remove_lighting and torch.cuda.is_available():
        status(2, "去除相片嘅光影（第一次要下載 AI）")
        colors_from = remove_lighting(cutout)

    status(3, "載入 AI，建立 3D 形狀")
    if args.engine == "hunyuan":
        engine = load_hunyuan()
        mesh = make_hunyuan(engine, cutout)
    else:
        # TripoSR takes its colors from the same photo it builds the shape from.
        engine = load_triposr(device)
        mesh = make_triposr(engine, colors_from, device, args.resolution)
    del engine
    if torch.cuda.is_available():
        torch.cuda.empty_cache()

    status(4, "整理同上色")
    mesh = drop_floating_bits(mesh)
    mesh = simplify(mesh, args.faces)
    mesh.fix_normals()
    if mesh.volume < 0:  # fix_normals can't tell inside from outside on open meshes
        mesh.invert()
    mesh = to_sketchup_space(mesh, args.engine)
    if args.engine == "hunyuan":
        mesh = paint_from_photo(mesh, colors_from)
    face_colors, palette = palette_colors(mesh, args.colors)

    write_result(args.out, {
        "vertices": [[round(float(c), 5) for c in v] for v in mesh.vertices],
        "faces": mesh.faces.tolist(),
        "face_colors": face_colors,
        "palette": palette,
    })
    status(STEPS, f"完成：{len(mesh.faces)} 個面")


def main():
    # Messages are in Cantonese; Windows log files would otherwise use the ANSI code page.
    for stream in (sys.stdout, sys.stderr):
        if stream is not None:
            stream.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", help="photo to turn into a model")
    parser.add_argument("--out", help="JSON file to write")
    parser.add_argument("--status", help="file that receives progress messages")
    parser.add_argument("--engine", choices=ENGINES, default="hunyuan")
    parser.add_argument("--faces", type=int, default=20000, help="max triangles")
    parser.add_argument("--colors", type=int, default=32, help="number of colors")
    parser.add_argument("--resolution", type=int, default=256, help="TripoSR shape detail grid")
    parser.add_argument("--keep-background", action="store_true")
    parser.add_argument("--remove-lighting", action="store_true",
                        help="take highlights, shadows and colored light out of the photo first (local engines)")
    parser.add_argument("--cpu", action="store_true", help="don't use the graphics card (TripoSR only)")
    parser.add_argument("--download-only", action="store_true",
                        help="only download the AI files, then exit")
    args = parser.parse_args()

    if not args.download_only and not (args.image and args.out):
        parser.error("--image and --out are required")

    status = Status(args.status)
    try:
        run(args, status)
    except Exception as error:
        traceback.print_exc()
        if args.out:
            with open(args.out + ".error.txt", "w", encoding="utf-8") as f:
                f.write(str(error) or type(error).__name__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
