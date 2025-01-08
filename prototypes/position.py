def value_slice(r, start_value, end_value):
    r_start = r.start
    r_step = r.step
    start = ((start_value - r_start) + (r_step - 1)) // r_step * r_step + r_start

    return start
