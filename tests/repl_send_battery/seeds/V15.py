from battery_standins import Anything
sitk = Anything("sitk")
torch = Anything("torch")
lm_fn = "lm.nii.gz"
def get_labels(lm):
    return [1]
