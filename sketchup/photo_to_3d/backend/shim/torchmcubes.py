"""Stand-in for torchmcubes, built on scikit-image.

The real torchmcubes has to be compiled with a CUDA compiler, which most
Windows PCs don't have. TripoSR only calls marching_cubes(), so this is enough.
"""

import numpy as np
import torch
from skimage import measure


def marching_cubes(volume, threshold):
    grid = volume.detach().float().cpu().numpy()
    if not grid.min() < threshold < grid.max():
        raise RuntimeError("張相搵唔到物件。試下用清楚啲、得一件嘢嘅相。")

    vertices, faces, _, _ = measure.marching_cubes(grid, level=threshold)

    # torchmcubes lists coordinates last-axis first; TripoSR flips them back.
    vertices = np.ascontiguousarray(vertices[:, ::-1], dtype=np.float32)
    return torch.from_numpy(vertices), torch.from_numpy(faces.astype(np.int64))
