using UnityEngine;

public class main : MonoBehaviour
{
    Material mat;
    Mesh mesh;

    Matrix4x4[] matrix = new Matrix4x4[3] ;

    Vector3 position1, position2, position3;
    Quaternion ratation1, ratation2, ratation3;

    bool _canntInstance = false;

    void Start()
    {
        mat = Resources.Load<Material>("scene_res/water_1/water_mat");
        mat.enableInstancing = true;
        mesh = Resources.Load<Mesh>("scene_res/water_1/test_mesh");

        position1 = transform.position + transform.forward * 15 + new Vector3(-5, -3, 0);
        ratation1 = Quaternion.identity;

        position2 = transform.position + transform.forward * 15 + new Vector3(3, -3, 0);
        ratation2 = Quaternion.identity;

        position3 = transform.position + transform.forward * 25 + new Vector3(0, -2, 0);
        ratation3 = Quaternion.identity;

        matrix[0] = Matrix4x4.TRS(position1, ratation1, Vector3.one);
        matrix[1] = Matrix4x4.TRS(position2, ratation2, Vector3.one);
        matrix[2] = Matrix4x4.TRS(position3, ratation3, Vector3.one);

        _canntInstance = Application.isMobilePlatform && SystemInfo.graphicsShaderLevel >= 50;
    }

    
    void Update()
    { 
        if (mat && mesh)
        {
            if (_canntInstance)
            {
                Graphics.DrawMesh(mesh, matrix[0], mat, 0);
                Graphics.DrawMesh(mesh, matrix[1], mat, 0);
                Graphics.DrawMesh(mesh, matrix[2], mat, 0);
            }
            else
            {
                Graphics.DrawMeshInstanced(mesh, 0, mat, matrix);
            }
        }
    }
}
