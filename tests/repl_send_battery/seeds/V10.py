import types
class _InferenceSession:
    def __init__(self, member):
        self.member = member
    def __enter__(self):
        return self
    def __exit__(self, *exc):
        return False
    def setup(self):
        pass
    def prepare_data(self, data, collate_fn=None):
        self.data = data
    def create_and_set_postprocess_transforms(self):
        pass
    def predict(self):
        return iter([1, 2])
    def postprocess(self, batch):
        return batch * 10
class WholeImageInferer:
    def __init__(self, *args, **kwargs):
        pass
class BaseInferer(WholeImageInferer):
    pass
E = types.SimpleNamespace(base_runs=["run1"], devices=[0], safe_mode=False, save_channels=False,
                          debug_base=False, decollate_base_predictions=lambda preds: preds)
get_mode_outchannels = lambda run: ("whole", 2)
data = [{"image": "img"}]
img_bbox_collated = None
