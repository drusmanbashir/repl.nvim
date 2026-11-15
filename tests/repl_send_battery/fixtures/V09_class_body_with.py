# repl_send_battery V09: class with nested def and for, blank lines, statements, a with-block.
# Copied verbatim from ~/code/fran/fran/preprocessing/helpers.py:564-589.
# %%
    import torch
    from torch import nn

    class TensorContainer(nn.Module):
        def __init__(self, tensor_dict):
            super().__init__()
            for key, value in tensor_dict.items():
                setattr(self, key, value)

    x = torch.ones(4, 4)
    tensor_dict = {"x": x}
    tensors = TensorContainer(tensor_dict)
    tensors = torch.jit.script(tensors)
    tensors.save(path)
    # 2) Verify the file format and the object type
    print("FILE_EXISTS:", os.path.exists(path))  # True
    print("IS_ZIPFILE (zipfile):", zipfile.is_zipfile(path))  # True

    with open(path, "rb") as f:
        print("IS_ZIPFILE (torch):", torch.serialization._is_zipfile(f))  # True

    obj = torch.load(path, map_location="cpu")
    print("PY_OBJ_TYPE:", type(obj))  # <class 'torch.Tensor'>
    print("PY_TENSOR_SHAPE:", obj.shape)

# %%
