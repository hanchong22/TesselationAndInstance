Shader "hc/Scene/Water"
{
	Properties{
		_Color("主颜色", Color) = (1, 1, 1, 1)
		_MainTex("主纹理(A通道作高度图)", 2D) = "white" {}
		_WaveMap("法线纹理", 2D) = "bump" {}
		_AlphaScale("透明度", Range(0, 1)) = 1

		_Cubemap("天空盒（用于反射的环境模拟）", Cube) = "_Skybox" {}
		_FresnelScale("反射倍数", Range(0, 1)) = 0
		_FresnelBias("反射范围", Range(0, 2)) = 1
		_WaveXSpeed("水平波纹速度", Range(-0.1, 0.1)) = 0.01
		_WaveYSpeed("垂直波纹速度", Range(-0.1, 0.1)) = 0.01

		//_Distortion ("折射率", Range(0, 1000)) = 10	

		[HDR]_Specular("高光颜色", Color) = (1, 1, 1, 1)
		_Gloss("高光范围", Range(0, 512)) = 20

		_Displacement("高度位移倍数", Range(0, 1.0)) = 0.3
		_TessEdgeLength("镶嵌边长，数值越小越精细", Range(2,100)) = 20
		//_TessPhongStrength( "镶嵌Phong强度", Range( 0,1 ) ) = 0.5
		//_TessExtrusionAmount( "镶嵌扩张度", Range( -1,1 ) ) = 0.0   
	}

	CGINCLUDE
		#include "UnityCG.cginc"
		#include "Lighting.cginc"
		#include "AutoLight.cginc"
		#include "Tessellation.cginc"	

		#define USING_FOG (defined(FOG_LINEAR) || defined(FOG_EXP) || defined(FOG_EXP2))	
		#pragma multi_compile_fog

		fixed4 _Color;
		sampler2D _MainTex;
		float4 _MainTex_ST;
		sampler2D _WaveMap;
		float4 _WaveMap_ST;
		samplerCUBE _Cubemap;
		fixed _WaveXSpeed;
		fixed _WaveYSpeed;
		//half _Distortion;	

		float _Displacement;


		//#ifndef WATER_SIMPLE
		//	sampler2D _RefractionTex;
		//	float4 _RefractionTex_TexelSize;
		//#endif

		fixed _FresnelScale;
		fixed _FresnelBias;

		fixed _AlphaScale;

		fixed4 _Specular;
		fixed _Gloss;

		half _TessEdgeLength;
		//half _TessPhongStrength;
		//half _TessExtrusionAmount;


		struct VertexInput {
			fixed4 color : COLOR;
			half4 vertex : POSITION;
			half3 normal : NORMAL;
			half4 tangent : TANGENT;
			half4 texcoord : TEXCOORD0;

			UNITY_VERTEX_INPUT_INSTANCE_ID

		};

		//镶嵌输入（顶点输出）
		struct InternalTessInterp_VertexInput
		{
			fixed4 color : COLOR;
			half4 vertex : INTERNALTESSPOS;
			half4 uv : TEXCOORD0;

			half3 normal : NORMAL;
			half4 tangent : TANGENT;

			UNITY_VERTEX_OUTPUT_STEREO
			UNITY_VERTEX_INPUT_INSTANCE_ID
			

		};

		//镶嵌输出（到片元）
		struct VertexOutput {
			fixed4 depth : COLOR;
			float4 	pos : SV_POSITION;

			float4 uv : TEXCOORD0;      	//两张图，需要float4做uv

			float4 TtoW0 : TEXCOORD1;
			float4 TtoW1 : TEXCOORD2;
			float4 TtoW2 : TEXCOORD3;
			//half4 scrPos : TEXCOORD4;     

#if USING_FOG
			fixed fog : TEXCOORD4;
			SHADOW_COORDS(5)

#else 
			SHADOW_COORDS(4)
#endif

			UNITY_VERTEX_OUTPUT_STEREO
			UNITY_VERTEX_INPUT_INSTANCE_ID
		};



		//顶点着色器，输出数据到镶嵌着色器（Tesselation Shader）
		InternalTessInterp_VertexInput tess_vert(VertexInput v)
		{
			InternalTessInterp_VertexInput o;

			UNITY_SETUP_INSTANCE_ID(v);
			UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
			UNITY_TRANSFER_INSTANCE_ID(v, o);

			o.vertex = v.vertex;
			o.uv = v.texcoord;
			o.normal = v.normal;
			o.tangent = v.tangent;
			o.color = v.color;
			return o;
		}

		// 镶嵌常量外壳着色器（tessellation hull constant shader）
		// 输出网格的镶嵌因子（tessallation factor）,输入为3个控制点
		UnityTessellationFactors hsconst_VertexInput(InputPatch<InternalTessInterp_VertexInput, 3> v)
		{
			//UnityEdgeLengthBasedTessCull为unity内置函数，作用是基于边长、控制点等参数计算镶嵌因子
			//UnityEdgeLengthBasedTessCull包含了超出视锥自动裁剪的功能，最后一个参数为超出多少距离就裁剪，如果为负数则会导致在视野内就会被裁剪
			UNITY_SETUP_INSTANCE_ID(v[0]);
			UNITY_SETUP_INSTANCE_ID(v[1]);
			UNITY_SETUP_INSTANCE_ID(v[2]);
			half4 tf = UnityEdgeLengthBasedTessCull(v[0].vertex, v[1].vertex, v[2].vertex, _TessEdgeLength, 0);
			//镶嵌因子
			UnityTessellationFactors o;
			UNITY_INITIALIZE_OUTPUT(UnityTessellationFactors, o);			
			o.edge[0] = tf.x;
			o.edge[1] = tf.y;
			o.edge[2] = tf.z;
			o.inside = tf.w;
			return o;
		}

		// 镶嵌控制点外壳着色器（tessellation hull shader），不做具体计算，仅充当传递着色器；InputPatch模板包含了面片所有控制点，系统值 SV_OutputControlPointID 为正在处理的控制点索引
		// 注意：输出控制点与输入控制点不一定相同，多出来的控制点可由输入的控制点所衍生
		//1、面片的类型，tri 为三角形，quad 为四边形， isoline 为等值线
		[UNITY_domain("tri")]
		//2、细分类型，integer为整数细分，会导致跳变；fractional_even/fractional_old为非整数类型
		[UNITY_partitioning("fractional_odd")]
		//3、通过细分所创建的三角形绕序,triangle_cw 顺针方向；Trangle_ccw 逆时针方向； line 针对线段曲面细分
		[UNITY_outputtopology("triangle_cw")]
		//4、指定的常量外壳着色器的函数名
		[UNITY_patchconstantfunc("hsconst_VertexInput")]
		//5、输出的控制点数量
		[UNITY_outputcontrolpoints(3)]//3个控制点
		//6、曲面细分因子的最大值（unity 似乎已经废弃此属性），directx11的最大值为64
		//[UNITY_maxtessfactor(64)]
		InternalTessInterp_VertexInput hs_VertexInput(InputPatch<InternalTessInterp_VertexInput, 3> v, uint id : SV_OutputControlPointID)
		{
			return v[id];
		}


		//镶嵌域着色器计算
		inline VertexInput _ds_VertexInput(UnityTessellationFactors tessFactors, const OutputPatch<InternalTessInterp_VertexInput, 3> vi, float3 bary : SV_DomainLocation)
		{
			VertexInput v;
			UNITY_INITIALIZE_OUTPUT(VertexInput, v);
			UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(v);
			v.vertex = vi[0].vertex * bary.x + vi[1].vertex * bary.y + vi[2].vertex * bary.z;
			v.color = vi[0].color * bary.x + vi[1].color * bary.y + vi[2].color * bary.z;
			v.tangent = vi[0].tangent * bary.x + vi[1].tangent * bary.y + vi[2].tangent * bary.z;
			v.normal = vi[0].normal * bary.x + vi[1].normal * bary.y + vi[2].normal * bary.z;
			v.texcoord = vi[0].uv * bary.x + vi[1].uv * bary.y + vi[2].uv * bary.z;

			/*
			//一个平面不需要phong进行平滑修正
			half3 pp[3];
			pp[0] = v.vertex.xyz - vi[0].normal * (dot(v.vertex.xyz, vi[0].normal) - dot(vi[0].vertex.xyz, vi[0].normal));
			pp[1] = v.vertex.xyz - vi[1].normal * (dot(v.vertex.xyz, vi[1].normal) - dot(vi[1].vertex.xyz, vi[1].normal));
			pp[2] = v.vertex.xyz - vi[2].normal * (dot(v.vertex.xyz, vi[2].normal) - dot(vi[2].vertex.xyz, vi[2].normal));
			v.vertex.xyz = _TessPhongStrength * (pp[0] * bary.x + pp[1] * bary.y + pp[2] * bary.z) + (1.0f - _TessPhongStrength) * v.vertex.xyz;

			//已有高度倍数，不再需要扩张倍数
			v.vertex.xyz += v.normal.xyz * _TessExtrusionAmount;
			*/

			float2 speed = _Time.z * float2(_WaveXSpeed, _WaveYSpeed);

			//主纹理的A通道作高度图
			float d1 = tex2Dlod(_MainTex, float4(v.texcoord.xy + speed, 0, 0)).a * _Displacement * v.color.r;
			float d2 = tex2Dlod(_MainTex, float4(v.texcoord.xy - speed, 0, 0)).a * _Displacement * v.color.r;

			v.vertex.xyz += v.normal * d1 + v.normal * d2;
			//v.tangent.xyz += v.normal * d1 + v.normal * d2;

			return v;
		}

		void vert_content(inout VertexOutput o, inout VertexInput v) {
			
			o.depth = v.color;
			o.pos = UnityObjectToClipPos(v.vertex);


			//o.scrPos = ComputeGrabScreenPos(o.pos);			
			o.uv.xy = TRANSFORM_TEX(v.texcoord, _MainTex);
			o.uv.zw = TRANSFORM_TEX(v.texcoord, _WaveMap);

			float3 worldPos = mul(unity_ObjectToWorld, v.vertex).xyz;
			float3 worldNormal = UnityObjectToWorldNormal(v.normal);
			float3 worldTangent = UnityObjectToWorldDir(v.tangent.xyz);
			float3 worldBinormal = cross(worldNormal, worldTangent) * v.tangent.w;

			o.TtoW0 = float4(worldTangent.x, worldBinormal.x, worldNormal.x, worldPos.x);
			o.TtoW1 = float4(worldTangent.y, worldBinormal.y, worldNormal.y, worldPos.y);
			o.TtoW2 = float4(worldTangent.z, worldBinormal.z, worldNormal.z, worldPos.z);

#if USING_FOG
			float3 eyePos = UnityObjectToViewPos(v.vertex);
			float fogCoord = length(eyePos.xyz);
			UNITY_CALC_FOG_FACTOR_RAW(fogCoord);
			o.fog = saturate(unityFogFactor);
#endif
			TRANSFER_SHADOW(o);
		}

		VertexOutput vert(VertexInput v) {
			VertexOutput o;

			UNITY_SETUP_INSTANCE_ID(v);
			UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
			UNITY_TRANSFER_INSTANCE_ID(v, o);

			vert_content(o, v);
			return o;
		}

		//镶嵌域着色器(tessellation domain shader),输出值到片段着色器		
		//1、面片类型：tri 表示三角形
		[UNITY_domain("tri")]
		VertexOutput ds_surf(UnityTessellationFactors tessFactors, const OutputPatch<InternalTessInterp_VertexInput, 3> vi, float3 bary : SV_DomainLocation)
		{
			UNITY_SETUP_INSTANCE_ID(vi[0]);
			UNITY_SETUP_INSTANCE_ID(vi[1]);
			UNITY_SETUP_INSTANCE_ID(vi[2]);

			VertexInput v = _ds_VertexInput(tessFactors, vi, bary);			

			VertexOutput o;	
			UNITY_INITIALIZE_OUTPUT(VertexOutput, o);
			UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
			UNITY_TRANSFER_INSTANCE_ID(v, o);
			vert_content(o, v);
			return o;			
		}



		fixed4 frag(VertexOutput i) : SV_Target{

			UNITY_SETUP_INSTANCE_ID(i);

			float3 worldPos = float3(i.TtoW0.w, i.TtoW1.w, i.TtoW2.w);
			float3 viewDir = normalize(UnityWorldSpaceViewDir(worldPos));
			float3 worldNormal = normalize(worldPos);
			float3 worldLightDir = normalize(UnityWorldSpaceLightDir(worldPos));
			float2 speed = _Time.y * float2(_WaveXSpeed, _WaveYSpeed);

			// Get the normal in tangent space
			float3 bump1 = UnpackNormal(tex2D(_WaveMap, i.uv.zw + speed)).rgb;
			float3 bump2 = UnpackNormal(tex2D(_WaveMap, i.uv.zw - speed)).rgb;
			float3 bump = normalize(bump1 + bump2);



			// Convert the normal to world space
			bump = normalize(float3(dot(i.TtoW0.xyz, bump), dot(i.TtoW1.xyz, bump), dot(i.TtoW2.xyz, bump)));


			fixed4 texColor = tex2D(_MainTex, i.uv.xy + speed);
			float3 reflDir = reflect(-viewDir, bump);


			// Compute the offset in tangent space
//#ifndef WATER_SIMPLE
//           	half2 offset = bump.xy * _Distortion * _RefractionTex_TexelSize.xy;
//            	i.scrPos.xy = offset * i.scrPos.z + i.scrPos.xy;
//            	float3 refrCol = tex2D( _RefractionTex, i.scrPos.xy/i.scrPos.w).rgb ;		
//#endif

			fixed3 reflCol = texCUBE(_Cubemap, reflDir).rgb * texColor.rgb * _Color.rgb * _FresnelScale;
			fixed fresnel = pow(_FresnelBias - saturate(dot(viewDir, bump)), 1);

			UNITY_LIGHT_ATTENUATION(atten, i, worldPos);

			float3 halfDir = normalize(worldLightDir + viewDir);
			float3 specular = _LightColor0.rgb * _Specular.rgb * pow(max(0, dot(bump, halfDir)), _Gloss) * atten;



			fixed alpha = 1;
			//#ifndef WATER_SIMPLE
			//			fixed3 ambient = UNITY_LIGHTMODEL_AMBIENT.xyz * reflCol * refrCol;
			//			fixed3 diffuse = refrCol *_LightColor0.rgb * reflCol * max(0, dot(worldNormal, worldLightDir)) * atten;				
			//          fixed3 finalColor =   reflCol * fresnel  + refrCol * (_FresnelBias - fresnel) * (1-_AlphaScale * i.depth.r);	
			//#else
				fixed3 ambient = UNITY_LIGHTMODEL_AMBIENT.xyz * reflCol;
				fixed3 diffuse = _LightColor0.rgb * reflCol * max(0, dot(worldNormal, worldLightDir)) * atten;
				fixed3 finalColor = reflCol * fresnel;
				alpha = _AlphaScale * i.depth.r;
			//#endif
			fixed4 col = float4(ambient + diffuse + finalColor + specular, alpha);



			#if USING_FOG
				col.rgb = lerp(unity_FogColor.rgb, col.rgb, i.fog);
			#endif

			return col;
		}



	ENDCG


	SubShader {
		Tags{ "Queue" = "Transparent"  "RenderType" = "Transparent" }
			LOD 500
			//屏幕图像用于折射(暂不需要)

			//GrabPass
			//{
			//	"_RefractionTex"			  
			//}

			Pass{
				Tags { "LightMode" = "ForwardBase" }
				Blend SrcAlpha OneMinusSrcAlpha

				CGPROGRAM
				#pragma target 5.0 
				#pragma multi_compile_fwdbase
				#pragma multi_compile_instancing

				#pragma vertex tess_vert			
				#pragma hull hs_VertexInput			
				#pragma domain ds_surf			
				#pragma fragment frag			
				ENDCG
		}
	}

	SubShader{
		Tags { "Queue" = "Transparent"  "RenderType" = "Transparent" }
		LOD 100
		//屏幕图像用于折射(暂不需要)

		//GrabPass
		//{
		//	"_RefractionTex"			  
		//}

		Pass {
			Tags { "LightMode" = "ForwardBase" }
			Blend SrcAlpha OneMinusSrcAlpha

			CGPROGRAM
			#pragma target 2.0 
			#pragma multi_compile_fwdbase
			#pragma multi_compile_instancing

			#pragma vertex vert
			#pragma fragment frag			
			ENDCG
		}
	}
	FallBack Off
}
