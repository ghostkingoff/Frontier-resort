// Keep all effects that lie on the ground in the same top-down projection.
// A factor of sqrt(2) compresses an upright texture to 1/sqrt(2) on screen.
vec2 project_ground_position(vec2 plane_position, float y_compression) {
	return vec2(
		plane_position.x,
		plane_position.y * max(y_compression, 0.001));
}
