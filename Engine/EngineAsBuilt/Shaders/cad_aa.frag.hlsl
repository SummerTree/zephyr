struct PSInput
{
    float4 pos : SV_Position;
    float4 color : COLOR;
    float2 uv : TEXCOORD1;
};

float4 main(PSInput input) : SV_Target0
{
    float4 color = input.color;
    float coreHalfPixels = input.uv.x;
    float signedDistancePixels = input.uv.y;

    float aa = 1.0;
    if (coreHalfPixels > 0.0) {
        float pixelFootprint = max(abs(ddx(signedDistancePixels)) + abs(ddy(signedDistancePixels)), 0.0001);
        aa = saturate(
            (coreHalfPixels + 0.5 * pixelFootprint - abs(signedDistancePixels))
            / pixelFootprint);
    }

    return float4(color.rgb, color.a * aa);
}
